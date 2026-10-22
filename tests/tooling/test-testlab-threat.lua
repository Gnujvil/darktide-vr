local Threat=dofile(assert(arg[1]))
local function fixture()
    local f={now=0,events={},hidden=true,cleanup_count=0}
    f.player={};f.enemy={};f.context={unit=f.player,session={},run='run1'};f.world=f.context
    f.flags={cs_enable_training_grounds_invisibility=true,cs_enable_training_grounds_invulnerability=nil}
    f.health={_is_invulnerable=true,value=100,
        set_invulnerable=function(self,value) if f.fail_restore and value then error('restore failure') end;self._is_invulnerable=value end,
        current_health=function(self) return self.value end,
        is_invulnerable=function(self) return self._is_invulnerable or f.keyword_invulnerable end}
    f.scenario={_current_scenario={},has_scenario_buff=function() return f.hidden and {} or false end,
        add_scenario_buff=function() f.hidden=true end,remove_scenario_buff=function() f.hidden=false end}
    f.perception={alert=function(_,unit,force) assert(unit==f.player and force);if f.fail_alert then error('alert failure') end end,
        aggro=function() f.aggro='aggroed' end,force_new_target_attempt=function() end,
        aggro_state=function() return f.aggro end,is_perception_disabled=function() return false end}
    f.minions={f.enemy};f.owned={{unit=f.enemy,id='owned1',breed='chaos_poxwalker'}}
    f.api=Threat.new({context=function() return f.context end,world=function() return f.world end,
        owned=function() return f.owned end,minions=function() return f.minions end,
        allied=function(_,other) return other==f.friendly end,
        alive=function(unit) return unit and not unit.dead end,health=function(unit) return unit==f.enemy and f.enemy_health or f.health end,
        scenario=function() return f.scenario end,creature=function() return {settings=f.flags} end,
        perception=function() return f.perception end,game_time=function() return 90 end,now=function() return f.now end,
        emit=function(kind,detail) f.events[#f.events+1]=kind..':'..detail end,
        cleanup=function() if f.fail_cleanup then return false,'despawn failure' end;f.cleanup_count=f.cleanup_count+1;f.enemy.dead=true;return true end,
        finish=function(context,reason) f.finish=reason;f.api.restore(reason) end})
    return f
end
local function restored(f)
    assert(f.api.status()=='idle' and f.flags.cs_enable_training_grounds_invisibility==true and
        f.flags.cs_enable_training_grounds_invulnerability==nil and f.cleanup_count==1,'exact original cache/owned cleanup not restored')
end
do
    local f=fixture();f.context.manual=true;f.api.begin(120,'manual_controller')
    f.enemy.dead=true;f.api.update();restored(f)
    assert(f.finish=='attacker_removed','manual enemy death did not end isolation')
    local ordinary=fixture()
    assert(not pcall(ordinary.api.begin,120,'ordinary'),'automated replay duration was widened')
    local corpse=fixture();corpse.context.manual=true
    corpse.enemy_health={current_health=function() return corpse.enemy.dead_health and 0 or 100 end}
    corpse.api.begin(120,'manual_corpse');corpse.enemy.dead_health=true;corpse.api.update()
    restored(corpse);assert(corpse.finish=='attacker_removed','live corpse delayed combat end')
end
do
    local f=fixture();f.api.begin(3,'request');assert(not f.hidden and not f.health._is_invulnerable and f.aggro=='aggroed')
    f.now=3;f.api.update();restored(f);assert(f.hidden and f.health._is_invulnerable and f.finish=='timeout')
    f.api.restore('duplicate');assert(f.cleanup_count==1)
end
for _,mode in ipairs({'health','context','scenario','death'}) do
    local f=fixture();f.api.begin(4,'request')
    if mode=='health' then f.health.value=50
    elseif mode=='context' then f.context=nil;f.world={unit={},session={}}
    elseif mode=='scenario' then f.scenario._current_scenario={}
    else f.player.dead=true end
    f.api.update();restored(f);assert(f.finish)
    if mode=='health' then assert(f.hidden and f.health._is_invulnerable) end
end
do
    local f=fixture();f.fail_alert=true
    assert(not pcall(f.api.begin,3,'bad'));restored(f);assert(f.hidden and f.health._is_invulnerable)
end
do
    local f=fixture();f.friendly={};f.minions[2]=f.friendly;f.api.begin(2,'ally')
    f.api.restore('stop');restored(f);assert(not f.friendly.dead,'native ally was mutated or destroyed')
end
do
    local f=fixture();f.keyword_invulnerable=true
    assert(not pcall(f.api.begin,3,'keyword'));restored(f)
end
for _,mode in ipairs({'foreign','not_registered','wrong_breed','duration','missing_capability'}) do
    local f=fixture()
    if mode=='foreign' then f.minions[2]={}
    elseif mode=='not_registered' then f.minions={}
    elseif mode=='wrong_breed' then f.owned[1].breed='chaos_ogryn_gunner'
    elseif mode=='missing_capability' then f.perception.alert=nil end
    assert(not pcall(f.api.begin,mode=='duration' and 13 or 3,'bad'))
    assert(f.api.status()=='idle' and f.hidden and f.health._is_invulnerable and f.cleanup_count==0,'refused episode changed native state')
end
do
    local f=fixture();f.api.begin(3,'request');f.fail_restore=true;f.fail_cleanup=true
    assert(not f.api.restore('stop') and f.api.status()=='restore_failed')
    assert(not pcall(f.api.begin,2,'new'),'new episode during restoration failure')
    f.fail_restore=false;f.fail_cleanup=false;f.now=.3;f.api.update();restored(f)
    assert(f.hidden and f.health._is_invulnerable)
end
if arg[2] then
    local base=arg[2]
    local Replay=dofile(base..'/scripts/mods/darktide_testlab/trajectory.lua')
    local parsed={}
    for _,name in ipairs({'guard_hold','incoming_idle'}) do
        local file=assert(io.open(base..'/'..name..'.tsv','r'))
        parsed[name]=assert(Replay.parse(file:read('*a')));file:close()
    end
    for _,time in ipairs({0,.5,3,7.5,8.2}) do
        local guard,idle=Replay.sample(parsed.guard_hold,time),Replay.sample(parsed.incoming_idle,time)
        for _,side in ipairs({'left','right'}) do
            for i=1,3 do assert(guard[side].position[i]==idle[side].position[i]) end
            for i=1,4 do assert(guard[side].rotation[i]==idle[side].rotation[i]) end
        end
        assert(not guard.buttons[1] and not idle.buttons[1] and not idle.buttons[2])
        if time>=.5 and time<=7.5 then assert(guard.buttons[2]) end
    end
end
print('testlab_threat=pass isolated_native_perception timeout health_budget owner_scenario_death_cleanup exact_cache_restore partial_arm_rollback retry no_foreign_mutation matched_guard_idle_replays')
