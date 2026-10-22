local mod=get_mod("darktide_testlab")
local Replay=mod:io_dofile("darktide_testlab/scripts/mods/darktide_testlab/trajectory")
local Startup=mod:io_dofile("darktide_testlab/scripts/mods/darktide_testlab/startup")
local Debug=mod:io_dofile("darktide_testlab/scripts/mods/darktide_testlab/debug_view")
local BuffSnapshot=mod:io_dofile("darktide_testlab/scripts/mods/darktide_testlab/buff_snapshot")
local Breeds=require("scripts/settings/breed/breeds")
local HumanInput=require("scripts/managers/player/player_game_states/human_input_handler")
local Sweep=require("scripts/extension_systems/weapon/actions/action_sweep")
local Attack=require("scripts/utilities/attack/attack")
local NavQueries=require("scripts/utilities/nav_queries")
local Push=require("scripts/extension_systems/weapon/actions/action_push")
local WeaponTemplate=require("scripts/utilities/weapon/weapon_template")
local MasterItems=require("scripts/backend/master_items")
local ProfilePackages=require("scripts/managers/ui/ui_character_profile_package_loader")
local VisualLoadout=require("scripts/extension_systems/visual_loadout/utilities/player_unit_visual_loadout")
local EquipmentComponent=require("scripts/extension_systems/visual_loadout/equipment_component")
local PlayerParticles=require("scripts/settings/particles/player_character_particles")
local PlayerSounds=require("scripts/settings/sound/player_character_sounds")
local PlayerDecals=require("scripts/settings/decal/player_character_decals")
local root="./../mods/darktide_testlab/"
local state={clock=0,poll=0,last_id=nil,stage="idle",run=nil,target=nil,suppressed=setmetatable({}, {__mode="k"})}
state.pinned_loaders={}
state.buff_proc_classes=setmetatable({}, {__mode="k"})
state.live_contacts=setmetatable({}, {__mode="k"})
local temporary_weapon
local targets
local threat
local isolation
local function restore_range_profile(reason)
    local snapshot=state.range_profile
    if snapshot then
        snapshot.settings.cs_enable_training_grounds_respawn=snapshot.respawn
        assert(snapshot.settings.cs_enable_training_grounds_respawn==snapshot.respawn,"range_respawn_restore_unverified")
        state.range_profile=nil
        -- Restore the setting, never delete or rebuild foreign native units.
        mod:info("TESTLAB range_profile_restored reason=%s original=%s",reason,tostring(snapshot.respawn))
    end
end
local function file_read(name)
    local f=Mods.lua.io.open(root..name,"r")
    if not f then return nil end
    local text=f:read(262145); f:close(); return text
end
local function write(name,text,mode)
    local f=Mods.lua.io.open(root..name,mode or "w")
    if f then f:write(text); f:close() end
end
local function event(kind,detail,id,batch)
    local run=state.run
    local line=string.format("%.6f\t%s\t%s\t%s\n",state.clock,id or (run and run.id) or "none",kind,tostring(detail or ""):gsub("[\r\n\t]"," "))
    if batch then batch[#batch+1]=line;return end
    write("results.tsv",line,"a")
    mod:info("TESTLAB %s",line:gsub("\n$",""))
end
local function player()
    -- local_player queries the native network peer; it is unsafe before a
    -- gameplay session exists, even inside pcall during a title-screen poll.
    if not (Managers.state and Managers.state.game_session) then return nil end
    return Managers.player and Managers.player:local_player(1)
end
local function local_range()
    local s=Managers.state
    return s and s.game_mode and s.game_mode:game_mode_name()=="shooting_range" and
        s.game_session and s.game_session:is_server()==true
end
local function health(unit)
    if not unit or not Unit.alive(unit) then return 0 end
    local ext=ScriptUnit.has_extension(unit,"health_system")
    return ext and ext:current_health() or -1
end
local function live_contact_observation(action)
    if state.run or not local_range() or not action._unit_data_extension or action._unit_data_extension.is_resimulating then return end
    local owner=Mods.darktidevr_physical_owners and Mods.darktidevr_physical_owners[action._player_unit]
    if not owner or not owner.owns or not owner.owns(action) then return end
    local data=state.live_contacts[action]
    if not data then
        state.live_contact_sequence=(state.live_contact_sequence or 0)+1
        if state.live_contact_sequence>128 then return end
        data={id="tracking_"..state.live_contact_sequence,queries=0,contacts=0,owned=0,selections=0,hits=0,damage_calls=0}
        state.live_contacts[action]=data
    end
    return data
end
local function target_context()
    local p=player()
    return local_range() and p and {unit=p.player_unit,session=Managers.state.game_session} or nil
end
targets=mod:io_dofile("darktide_testlab/scripts/mods/darktide_testlab/targets").new({
    alive=Unit.alive,health=health,emit=event,
    spawn=function(spec)
        assert(not state.native_attacker_spawn,"nested_attacker_spawn_refused")
        state.native_attacker_spawn=spec.active==true;state.spawn_ai_gate_reads=0
        local ok,unit=pcall(Managers.state.minion_spawn.spawn_minion,Managers.state.minion_spawn,spec.breed,spec.position:unbox(),spec.rotation:unbox(),2)
        state.native_attacker_spawn=false -- clear even if native initialization fails
        if not ok then error(unit,0) end
        return unit
    end,
    destroy=function(unit) Managers.state.minion_spawn:despawn_minion(unit) end})
local observations=mod:io_dofile("darktide_testlab/scripts/mods/darktide_testlab/observations").new({
    identity=function(run,unit)
        if not unit then return "none" end
        if unit==run.unit then return "local_player" end
        local entry=targets.find(run.targets,unit)
        return entry and entry.id or "foreign"
    end,
    read=function(run,unit)
        if Managers.state.game_session~=run.session or not unit or not Unit.alive(unit) then return {} end
        local h=ScriptUnit.has_extension(unit,"health_system")
        local tough=ScriptUnit.has_extension(unit,"toughness_system")
        local data=ScriptUnit.has_extension(unit,"unit_data_system")
        local stamina,block
        if data and unit==run.unit then
            local ok,value=pcall(data.read_component,data,"stamina");if ok then stamina=value end
            ok,value=pcall(data.read_component,data,"block");if ok then block=value end
        end
        return {health=h and h:current_health(),toughness=tough and tough.remaining_toughness and tough:remaining_toughness(),
            stamina=stamina and stamina.current_fraction,blocking=block and block.is_blocking,
            invulnerable=h and h.is_invulnerable and h:is_invulnerable(),unkillable=h and h.is_unkillable and h:is_unkillable()}
    end,
    report=function(run,data)
        if data.kind=="native_attack" then
            if data.incoming then
                run.incoming=(run.incoming or 0)+1
                run.incoming_blocked=(run.incoming_blocked or 0)+(data.result=="blocked" and 1 or 0)
                run.incoming_unknown=(run.incoming_unknown or 0)+(data.health_valid and data.toughness_valid and 0 or 1)
                run.incoming_health=(run.incoming_health or 0)+(data.health_valid and data.health_delta or 0)
                run.incoming_toughness=(run.incoming_toughness or 0)+(data.toughness_valid and data.toughness_delta or 0)
                run.incoming_protected=(run.incoming_protected or 0)+(data.before.invulnerable==true and 1 or 0)
            end
            if data.health_valid and data.after.health==0 then
                for _,entry in ipairs(run.targets) do
                    if entry.id==data.target then entry.confirmed_zero=true end
                end
            end
            event(data.kind,string.format("incoming=%s target=%s attacker=%s result=%s damage_return=%s health_before=%s health_after=%s health_delta=%s health_valid=%s toughness_before=%s toughness_after=%s toughness_delta=%s toughness_valid=%s stamina_delta=%s blocking=%s invulnerable=%s unkillable=%s profile=%s damage_type=%s attack_type=%s zone=%s critical=%s target_index=%s target_number=%s",
                tostring(data.incoming),data.target,data.attacker,tostring(data.result),tostring(data.damage_return),tostring(data.before.health),tostring(data.after.health),tostring(data.health_delta),tostring(data.health_valid),
                tostring(data.before.toughness),tostring(data.after.toughness),tostring(data.toughness_delta),tostring(data.toughness_valid),tostring(data.stamina_delta),tostring(data.before.blocking),tostring(data.before.invulnerable),tostring(data.before.unkillable),
                data.profile,tostring(data.metadata.damage_type),tostring(data.metadata.attack_type),tostring(data.metadata.hit_zone_name),tostring(data.metadata.is_critical_strike),tostring(data.metadata.target_index),tostring(data.metadata.target_number)),run.id)
        elseif data.kind=="native_proc_queue" then
            run.proc_queued=(run.proc_queued or 0)+(data.queued and 1 or 0)
            event(data.kind,string.format("event=%s owner=%s attacker=%s target=%s result=%s damage=%s actual_damage=%s queued=%s before_count=%s after_count=%s extension_class=%s",
                data.event,data.owner,data.attacker,data.target,tostring(data.result),tostring(data.damage),tostring(data.actual_damage),tostring(data.queued),tostring(data.before_count),tostring(data.after_count),data.extension_class),run.id)
        else
            local counts={};for name,number in pairs(data.events) do counts[#counts+1]=name..":"..number end;table.sort(counts)
            run.buff_activations=(run.buff_activations or 0)+(data.activated and 1 or 0)
            run.buff_snapshot_pending=true
            event(data.kind,string.format("owner=%s template=%s buff_class=%s time=%s native_activated=%s input_events=%s native_event_counts=%s counts_known=%s truncated=%s seed_before=%s seed_after=%s local_seed_before=%s local_seed_after=%s",
                data.owner,data.template,data.buff_class,tostring(data.time),tostring(data.activated),tostring(data.event_count),table.concat(counts,","),
                tostring(data.events_known),tostring(data.truncated),tostring(data.seed_before),tostring(data.seed_after),tostring(data.local_seed_before),tostring(data.local_seed_after)),run.id)
        end
    end})
local function capture_buffs(context,extension,phase,request,t,frame)
    if not local_range() or Managers.state.game_session~=context.session or not Unit.alive(context.unit) then
        event("buff_snapshot_error","context_changed",request);return false
    end
    local clock=Mods.lua.os and Mods.lua.os.clock
    local started=clock and clock()
    local snapshot=BuffSnapshot.capture(extension)
    local gear_ok,gear,weapon_name=pcall(function()
        local ext=ScriptUnit.has_extension(context.unit,"weapon_system")
        local weapon=ext and ext._weapons[ext._inventory_component.wielded_slot]
        return weapon and weapon.item and weapon.item.gear_id,weapon and weapon.weapon_template.name
    end)
    state.buff_snapshot_sequence=(state.buff_snapshot_sequence or 0)+1
    local sequence=state.buff_snapshot_sequence
    local same=phase=="post_proc" and BuffSnapshot.same(snapshot,context.last_buff_snapshot)
    local prefix=string.format("snapshot=%d phase=%s frame=%s time=%s ",sequence,phase,tostring(frame),tostring(t))
    local stats,keywords=0,0
    local data_rows={}
    for _ in pairs(snapshot.stats) do stats=stats+1 end
    for _ in pairs(snapshot.keywords) do keywords=keywords+1 end
    if not same then
        for _,buff in ipairs(snapshot.buffs) do
            event("buff_item",prefix..string.format("name=%s stacks=%s instance_id=%s buff_class=%s",buff.name,tostring(buff.stacks),tostring(buff.instance_id),buff.buff_class),request,data_rows)
        end
        local names={};for name in pairs(snapshot.stats) do names[#names+1]=name end;table.sort(names)
        for _,name in ipairs(names) do event("buff_stat",prefix.."name="..name.." value="..tostring(snapshot.stats[name]),request,data_rows) end
        names={};for name in pairs(snapshot.keywords) do names[#names+1]=name end;table.sort(names)
        for _,name in ipairs(names) do event("buff_keyword",prefix.."name="..name.." value="..tostring(snapshot.keywords[name]),request,data_rows) end
        context.last_buff_snapshot=snapshot;context.last_buff_snapshot_sequence=sequence
    end
    -- One append for scalar data; keep console output to snapshot summaries.
    if #data_rows>0 then write("results.tsv",table.concat(data_rows),"a") end
    event("buff_snapshot",prefix..string.format("source=read_only_native scope=materialized_numeric_stats complete=%s truncated=%s buffs=%d stats=%d keywords=%d unchanged_from=%s gear_id=%s weapon=%s errors=%s",
        tostring(snapshot.complete),tostring(snapshot.truncated),#snapshot.buffs,stats,keywords,
        same and tostring(context.last_buff_snapshot_sequence) or "none",gear_ok and tostring(gear) or "unavailable",
        gear_ok and tostring(weapon_name) or "unavailable",table.concat(snapshot.errors,";")),request)
    context.buff_snapshots=(context.buff_snapshots or 0)+1
    event("buff_snapshot_cost",prefix..string.format("clock_seconds=%s clock=LuaJIT_os.clock scope=capture_and_logging_excludes_metric_row data_rows=%d",
        started and string.format("%.9f",clock()-started) or "unavailable",same and 0 or #snapshot.buffs+stats+keywords),request)
    return true
end
local function cancel_native(run)
    if run.runtime then run.runtime.invalidate("cancel"); run.physical_action=nil; return end
        -- End the native action as well as our queries. Otherwise unloading
        -- DMF hooks mid-stroke could restore an authored hit window later.
        if run.physical and run.simulation_t and local_range() and Unit.alive(run.unit) and
                run.weapon_extension._weapons[run.slot]==run.weapon then
            local ok,err=pcall(run.weapon_extension.stop_action,run.weapon_extension,"unwield",nil,run.simulation_t,false)
            if not ok then event("native_cancel_error",err,run.id)
            else
                local component=run.weapon_extension._weapon_action_component
                event("native_cancel","action="..tostring(component and component.current_action_name),run.id)
            end
        end
    run.physical_action=nil; run.pending_stroke=nil; run.pulse_frame=nil; run.release_frame=nil
end
local function result(run,reason)
    if run.result_emitted then return end
    run.result_emitted=true
    if local_range() and Managers.state.game_session==run.session and Unit.alive(run.unit) then
        local ok,err=pcall(function()
            capture_buffs(run,ScriptUnit.has_extension(run.unit,"buff_system"),"terminal",run.id,run.simulation_t,run.frame)
        end)
        if not ok then event("buff_snapshot_error",err,run.id) end
    end
    -- A vanished/replaced target or session is not evidence of a kill. Keep
    -- the last observed health separate from the final, identity-checked read.
    local valid=Managers.state and Managers.state.game_session==run.session and
        state.target==run.target and state.target_id==run.target_id and
        state.target_generation==run.target_generation
    local source="unavailable"
    local ok,after=pcall(function()
        if not valid then return -1 end
        if run.target and Unit.alive(run.target) then
            local value=health(run.target)
            if value>=0 then source="health_extension";return value end
        end
        if run.confirmed_native_kill or run.confirmed_zero then
            source=run.confirmed_native_kill and "native_kill" or "observed_zero_before_removal";return 0
        end
        return -1
    end)
    valid=ok and after>=0 and run.before>=0
    after=valid and after or -1
    local total,total_valid,total_native,total_hits=0,true,0,0
    for _,entry in ipairs(run.targets or {}) do
        if entry.id==run.target_id then
            entry.confirmed_native_kill=entry.confirmed_native_kill or run.confirmed_native_kill
            entry.confirmed_zero=entry.confirmed_zero or run.confirmed_zero
        end
        local outcome=targets.outcome(entry,target_context())
        total_valid=total_valid and outcome.valid
        total=total+outcome.delta
        total_native=total_native+entry.native_damage;total_hits=total_hits+entry.hits
        event("target_result",string.format("target=%s generation=%s breed=%s before=%.5f after=%.5f health_delta=%.5f health_valid=%s health_source=%s native_damage=%.5f hits=%d outcome=%s reason=%s",
            entry.id,tostring(entry.generation),entry.breed,outcome.before,outcome.after,outcome.delta,tostring(outcome.valid),outcome.source,
            entry.native_damage,entry.hits,reason=="complete" and "complete" or "aborted",reason),run.id)
    end
    event("owned_result",string.format("targets=%d health_valid=%s health_delta=%.5f native_damage=%.5f hits=%d",
        #(run.targets or {}),tostring(total_valid),total_valid and total or -1,total_native,total_hits),run.id)
    event("incoming_result",string.format("attacks=%d blocked=%d protected=%d resource_unknown=%d health_delta=%.5f toughness_delta=%.5f native_proc_queued=%d native_buff_activations=%d buff_snapshots=%d",
        run.incoming or 0,run.incoming_blocked or 0,run.incoming_protected or 0,run.incoming_unknown or 0,run.incoming_health or 0,run.incoming_toughness or 0,run.proc_queued or 0,run.buff_activations or 0,run.buff_snapshots or 0),run.id)
    event("result",string.format("sweeps=%d hits=%d visual_samples=%d max_pose_error=%.6f max_weapon_error=%.6f before=%.3f after=%.3f health_delta=%.3f native_damage=%.3f max_weight_lag=%.6f max_weight_angle=%.6f strokes=%d support_frames=%d mass_min=%.6f mass_max=%.6f physical_failure=%s outcome=%s reason=%s health_valid=%s last_observed_health=%.3f target=%s generation=%s frame=%s exit_entered=%d exit_completed=%d proc_entered=%d proc_completed=%d health_source=%s",
        run.sweeps,run.hits,run.samples,run.max_visual_error or -1,run.max_weapon_error or -1,
        run.before,after,valid and run.before-after or -1,run.native_damage or 0,
        run.max_weight_lag or 0,run.max_weight_angle or 0,run.strokes_committed or 0,
        run.support_frames or 0,run.mass_min or -1,run.mass_max or -1,tostring(run.physical_failure),
        reason=="complete" and "complete" or "aborted",tostring(reason),tostring(valid),run.after or -1,
        tostring(run.target_id),tostring(run.target_generation),tostring(run.frame),
        run.exit_entered or 0,run.exit_completed or 0,run.proc_entered or 0,run.proc_completed or 0,valid and source or "unavailable"),run.id)
end
local function cleanup(reason)
    if not state.auto_combat then state.empty_combat=nil end -- preserve armed suppression through the hub-to-range transition
    if (state.manual or state.manual_pending) and state.combat_range_profile then state.restore_combat_range=true end
    state.manual_pending=nil
    state.manual=nil
    local run=state.run
    if run then
        -- Retire ownership first: a failed visual restore cannot leave an
        -- invisible test collider or scripted input authoring active.
        state.run=nil
        local function release(name,fn)
            local ok,err=pcall(fn)
            if not ok then event("cleanup_error",name..":"..tostring(err),run.id) end
        end
        release("native",function() cancel_native(run) end)
        if run.runtime then release("runtime",run.runtime.close) end
        if run.lease then release("lease",function() run.LeaseApi.release_source(run.unit,run.lease) end) end
        if run.strokes then release("strokes",run.strokes.invalidate) end
        if run.debug then release("debug",run.debug.destroy) end
        if run.weighted then release("weighted",run.weighted.close) end
        for _,original in pairs(run.visual_originals or {}) do
            if Unit.alive(original.unit) then
            local ok,err=pcall(function()
                Unit.set_local_position(original.unit,1,original.position:unbox())
                Unit.set_local_rotation(original.unit,1,original.rotation:unbox())
            end)
            if not ok then event("restore_error",err,run.id) end
            end
        end
        release("result",function() result(run,reason) end)
        release("stop",function() event("stop",reason,run.id) end)
    end
    if threat then
        local ok,why=threat.restore(reason)
        if not ok then return ok,why end
    end
    if isolation then
        local ok,why=pcall(isolation.restore,reason)
        if not ok then event("combat_restore_error",why);return false,"combat_range_restoration_pending" end
        if not why then return false,"combat_range_restoration_pending" end
    end
    if state.restore_combat_range and not isolation.active() then
        restore_range_profile(reason)
        state.restore_combat_range=nil;state.combat_range_profile=nil
    end
    return true
end
threat=mod:io_dofile("darktide_testlab/scripts/mods/darktide_testlab/threat").new({
    context=function()
        local run=state.run
        if run and run.physical and local_range() and Managers.state.game_session==run.session then
            return {unit=run.unit,session=run.session,run=run.id}
        end
        local current=target_context()
        if state.manual and current and state.manual.unit==current.unit and state.manual.session==current.session then
            return state.manual
        end
    end,
    world=target_context,owned=targets.entries,alive=Unit.alive,
    allied=function(player_unit,other)
        local side=Managers.state.extension:system("side_system")
        return side and side.side_by_unit and side.side_by_unit[player_unit] and side.side_by_unit[other] and
            type(side.is_ally)=="function" and side:is_ally(player_unit,other)==true or false
    end,
    minions=function() return Managers.state and Managers.state.minion_spawn and Managers.state.minion_spawn._spawned_minions end,
    describe=function(unit)
        local data=ScriptUnit.has_extension(unit,"unit_data_system")
        local breed=data and data:breed()
        local perception=ScriptUnit.has_extension(unit,"perception_system")
        local position=Unit.world_position(unit,1)
        return "breed="..tostring(breed and breed.name).." health="..health(unit)..
            " aggro="..tostring(perception and perception:aggro_state())..
            string.format(" position=%.3f,%.3f,%.3f",Vector3.x(position),Vector3.y(position),Vector3.z(position))
    end,
    health=function(unit) return ScriptUnit.has_extension(unit,"health_system") end,
    perception=function(unit) return ScriptUnit.has_extension(unit,"perception_system") end,
    scenario=function()
        local manager=Managers.state and Managers.state.extension
        if not manager or not manager.system then return nil end
        local ok,system=pcall(manager.system,manager,"scripted_scenario_system")
        return ok and system or nil
    end,
    creature=function() return get_mod("creature_spawner") end,
    game_time=function() return Managers.time:time("gameplay") end,
    now=function() return state.clock end,emit=event,
    cleanup=function()
        local ok,why=targets.clear(target_context())
        if ok then state.target=nil;state.target_id=nil end
        return ok,why
    end,
    finish=function(context,reason)
        if state.manual and state.manual.run==context.run then
            assert(threat.restore(reason),"manual_attacker_restoration_pending")
            event("combat_enemy_finished","reason="..reason.." manual_spawn_required=true",context.run)
        elseif state.run and state.run.id==context.run then cleanup("threat_"..reason) end
    end})
isolation=mod:io_dofile("darktide_testlab/scripts/mods/darktide_testlab/range_isolation").new({
    context=target_context,
    scenario=function() return Managers.state.extension:system("scripted_scenario_system") end,
    settings=function() return get_mod("creature_spawner").settings end,
    minions=function() return Managers.state.minion_spawn._spawned_minions end,
    allied=function(unit,other)
        local side=Managers.state.extension:system("side_system")
        return side and side.side_by_unit and side.side_by_unit[unit] and side.side_by_unit[other] and side:is_ally(unit,other)==true
    end,
    alive=Unit.alive,retire=function(unit)
        -- Only the isolation snapshot's native range targets reach this
        -- callback. Use native unregister/deletion, without dissolve VFX.
        Managers.state.minion_spawn:despawn_minion(unit)
    end,
    time=function() return Managers.time:time("gameplay") end,emit=event,
})
local function elapsed(run) return run.elapsed or 0 end
local function target_state(run,phase)
    if not run then return end
    for _,entry in ipairs(run.targets or {}) do
        if entry.unit and Unit.alive(entry.unit) then
            local p=Unit.world_position(entry.unit,1)
            event("target_state",string.format("phase=%s frame=%s target=%s generation=%s position=%.5f,%.5f,%.5f health=%.5f",
                phase,tostring(run.frame),entry.id,tostring(entry.generation),Vector3.x(p),Vector3.y(p),Vector3.z(p),health(entry.unit)))
        end
    end
end
local function camera()
    local p=player()
    if not p or not p.player_unit or not Unit.alive(p.player_unit) then return nil end
    local c=Managers.state.camera
    return c:camera_position(p.viewport_name),c:camera_rotation(p.viewport_name)
end
local function world_pose(run,sample)
    local p,q=sample.position,sample.rotation
    local anchor=run.anchor:unbox()
    return run.origin:unbox()+Quaternion.rotate(anchor,Vector3(p[1],p[2],p[3])),
        Quaternion.multiply(anchor,Quaternion.from_elements(q[1],q[2],q[3],q[4]))
end
local function pose(run,hand,t)
    local current=run.runtime and run.runtime.latest()
    if current and current.pose_time==t then
        local world=current.world_support
        if hand=="right" then world=current.world end
        if world then return Vector3(unpack(world.position)),Quaternion.from_elements(unpack(world.rotation)) end
    end
    local sample
    if run.weighted then
        local weighted=assert(run.weighted.at(t),"weighted pose was not sampled by simulation")
        if hand=="right" then sample=weighted
        else sample=weighted.support or Replay.sample(run.keys,t)[hand] end
    else sample=Replay.sample(run.keys,t)[hand] end
    return world_pose(run,sample)
end
local function despawn()
    local ok,why=targets.clear(target_context());assert(ok,why)
    state.target=nil
    state.target_id=nil
end
local function spawn(breed,distance,request_id,count,spacing,active)
    assert(local_range(),"local Psykhanium required")
    assert(Breeds[breed],"unknown breed")
    assert(distance and distance>=.8 and distance<=4,"distance must be 0.8..4 metres")
    count=count or 1;spacing=spacing or .6
    assert(not active or (breed=="chaos_poxwalker" and count==1),"attacker_requires_one_poxwalker")
    assert(count>=1 and count<=5 and count==math.floor(count),"target count must be 1..5")
    assert(spacing>=.35 and spacing<=1.5,"target spacing must be 0.35..1.5 metres")
    local origin,rotation=camera(); assert(origin,"player unavailable")
    local forward=Quaternion.forward(rotation); forward.z=0
    forward=Vector3.normalize(forward)
    local p=player().player_unit
    local world=Managers.world:world("level_world")
    local physics=World.get_data(world,"physics_world")
    local nav_world=Managers.state.extension:system("navigation_system"):get_nav_world()
    local right=Quaternion.rotate(rotation,Vector3(1,0,0));right.z=0;right=Vector3.normalize(right)
    local specs={}
    for i=1,count do
        local floor=Unit.world_position(p,1)+forward*distance+right*((i-(count+1)/2)*spacing)
        local hit,pos=PhysicsWorld.immediate_raycast(physics,floor+Vector3(0,0,1.5),Vector3(0,0,-1),4,
            "closest","types","statics","collision_filter","filter_player_character_shooting_raycast_statics")
        assert(hit and pos,"no floor under target")
        pos=NavQueries.position_on_mesh(nav_world,pos,1,1);assert(pos,"target position outside navigation mesh")
        specs[i]={id=count==1 and request_id or request_id..":"..i,generation=(state.target_generation or 0)+1,
            breed=breed,active=active,position=Vector3Box(pos),rotation=QuaternionBox(Quaternion.look(-forward))}
    end
    local entries=targets.replace(specs,target_context())
    local primary=entries[math.ceil(count/2)]
    state.target=primary.unit
    state.target_breed=breed
    state.target_generation=(state.target_generation or 0)+1
    state.target_id=primary.id
    if active then
        local perception=ScriptUnit.has_extension(primary.unit,"perception_system")
        local disabled=perception and perception.is_perception_disabled and perception:is_perception_disabled()
        event("spawn_ai_init","target="..primary.id.." native_gate_reads="..tostring(state.spawn_ai_gate_reads).." perception_disabled="..tostring(disabled),request_id)
        assert(disabled==false,"native_attacker_perception_init_unverified")
    end
    for i,entry in ipairs(entries) do
        local pos=specs[i].position:unbox()
        event("spawn",string.format("target=%s generation=%d breed=%s distance=%.3f health=%.3f position=%.5f,%.5f,%.5f group_count=%d primary=%s",
            entry.id,state.target_generation,breed,distance,health(entry.unit),Vector3.x(pos),Vector3.y(pos),Vector3.z(pos),count,tostring(entry==primary)),request_id)
    end
end
local function run_case(id,arguments)
    assert(threat.status()=="idle","stop and restore attacking episode before a new replay")
    assert(not temporary_weapon or temporary_weapon.status()=="idle" or temporary_weapon.status()=="active","temporary_weapon_not_ready")
    local words={}; for word in arguments:gmatch("%S+") do words[#words+1]=word end
    assert(#words>=1 and #words<=5,"run requires scenario [profile] [stock|physical|physical-heavy] [duration_scale] [fixed|player]")
    local name,profile,mode,scale=words[1],words[2],words[3],tonumber(words[4] or "1")
    assert(not mode or mode=="physical" or mode=="physical-heavy" or mode=="stock","unknown attack mode")
    local physical=mode=="physical" or mode=="physical-heavy"
    local anchor_mode=words[5] or "fixed"
    assert(anchor_mode=="fixed" or anchor_mode=="player","unknown anchor mode")
    assert(anchor_mode~="player" or physical,"player anchor requires physical mode")
    assert(scale and scale>=.25 and scale<=4,"duration scale must be 0.25..4")
    if profile=="raw" then profile=nil end
    assert(not physical or profile,"physical attacks require a native inertia profile; raw remains a stock-window baseline")
    assert(local_range(),"local Psykhanium required")
    assert(state.target and health(state.target)>0,"spawn a living test target first")
    assert(name:match("^[%w_-]+%.tsv$"),"scenario must be a local TSV filename")
    local source=file_read(name)
    local keys,reason=Replay.parse(source); assert(keys,reason)
    assert(keys[#keys].t*scale<=30,"scaled scenario exceeds 30 seconds")
    local checksum=0
    for i=1,#source do checksum=(checksum*131+source:byte(i))%4294967296 end
    for _,key in ipairs(keys) do key.t=key.t*scale end
    local origin,rotation=camera(); assert(origin,"player unavailable")
    local p=player(); local data=ScriptUnit.extension(p.player_unit,"unit_data_system")
    local Lease=mod:io_dofile("darktide_testlab/scripts/mods/darktide_testlab/melee_runtime")
    local producer=Lease.owner(p.player_unit)
    assert(not producer or state.run and (state.run.runtime==producer or state.run.lease==producer),
        "stop the other melee pose producer before arming replay")
    local inventory=data:read_component("inventory")
    assert(inventory.wielded_slot=="slot_primary","wield melee weapon before running")
    local extension=ScriptUnit.has_extension(p.player_unit,"weapon_system")
    local weapon=extension and extension._weapons and extension._weapons[inventory.wielded_slot]
    assert(weapon and weapon.weapon_template,"melee weapon context is not ready")
    local config
    if profile then
        local Weapons=mod:io_dofile("darktide_testlab/scripts/mods/darktide_testlab/melee_weapons")
        local reason
        config,reason=Weapons.resolve(weapon.weapon_template,profile);assert(config,reason)
        profile=config.profile
    end
    assert(cleanup("replaced"),"threat_restoration_pending")
    local weighted
    if profile then
        assert(profile=="knife" or profile=="sword" or profile=="axe" or profile=="hammer","unknown weight profile")
        local Inertia=mod:io_dofile("darktide_testlab/scripts/mods/darktide_testlab/melee_inertia")
        local Owner=mod:io_dofile("darktide_testlab/scripts/mods/darktide_testlab/melee_pose")
        local reason
        config.library_path=root.."bin/darktidevr_melee_inertia.dll"
        weighted,reason=Owner.new(Inertia,config)
        assert(weighted,reason)
        event("inertia_config",string.format("id=%s source=%s estimated=%s mass=%s length=%s head_fraction=%s",
            config.id,config.source,tostring(config.estimated or false),tostring(config.body and config.body.mass),
            tostring(config.body and config.body.length),tostring(config.body and config.body.head_fraction)),id)
    end
    state.run={id=id,keys=keys,start=state.clock,origin=Vector3Box(origin),anchor=QuaternionBox(rotation),
        anchor_mode=anchor_mode,initial_origin=Vector3Box(origin),player_origin=Vector3Box(Unit.world_position(p.player_unit,1)),
        unit=p.player_unit,slot=inventory.wielded_slot,target=state.target,before=health(state.target),targets=targets.capture(target_context()),
        sweeps=0,hits=0,samples=0,source=name,timeline={},weapon=weapon,weapon_extension=extension,
        session=Managers.state.game_session,last_step_wall=state.clock,weighted=weighted,profile=profile or "raw",
        heavy_enabled=mode=="physical-heavy",duration_scale=scale,debug=Debug.new(),target_generation=state.target_generation,target_id=state.target_id,reference={}}
    if physical then
        local function load(suffix)
            local module=mod:io_dofile("darktide_testlab/scripts/mods/darktide_testlab/melee_"..suffix)
            assert(type(module)=="table","failed to load melee "..suffix); return module
        end
        local run=state.run
        run.Timing=load("timing"); run.Volume=load("volume"); run.Planner=load("sweep_plan")
        run.defaults=require("scripts/settings/equipment/action_sweep_settings")
        if state.stroke_unit~=p.player_unit or state.stroke_session~=run.session then
            state.strokes=load("strokes").new(); state.stroke_unit=p.player_unit; state.stroke_session=run.session
        end
        run.strokes=state.strokes; run.physical=true
        event("attack_mode",mode)
        run.runtime=load("runtime").new({Timing=run.Timing,Volume=run.Volume,Planner=run.Planner,Bridge=load("action_bridge"),Defense=load("defense"),Tether=load("tether")},{
            source="synthetic",owner=weighted,strokes=run.strokes,extension=extension,weapon=weapon,slot=run.slot,
            unit=run.unit,defaults=run.defaults,cancel_on_adopt=true,native_events=true,
            to_world=function(value) return world_pose(run,value) end,
            freeze_world=function(p,q)
                return {position={Vector3.x(p),Vector3.y(p),Vector3.z(p)},rotation={Quaternion.to_elements(q)}}
            end,
            world_components=function(value)
                return Vector3(unpack(value.position)),Quaternion.from_elements(unpack(value.rotation))
            end,
            to_world_direction=function(value) return Quaternion.rotate(run.anchor:unbox(),Vector3(value[1],value[2],value[3])) end,
            sticky_frame=function(action)
                return load("tether").native_frame(action,function(p,q)
                    local x,y,z,w=Quaternion.to_elements(run.anchor:unbox())
                    local inverse_anchor=Quaternion.from_elements(-x,-y,-z,w)
                    local local_p=Quaternion.rotate(inverse_anchor,p-run.origin:unbox())
                    x,y,z,w=Quaternion.to_elements(Quaternion.multiply(inverse_anchor,q))
                    return {position={Vector3.x(local_p),Vector3.y(local_p),Vector3.z(local_p)},rotation={x,y,z,w}}
                end)
            end,
            cancel_native=function(t)
                if local_range() and Unit.alive(run.unit) and extension._weapons[run.slot]==weapon then
                    extension:stop_action("unwield",nil,t,false)
                    event("native_cancel","action="..tostring(extension._weapon_action_component.current_action_name),run.id)
                end
            end,
            emit=function(kind,data)
                if kind=="stroke" then
                    run.strokes_committed=(run.strokes_committed or 0)+1
                    event("stroke",string.format("id=%d interval=%.6f action=%s source=%s intent_hand=%s",data.id,data.interval,data.action,data.source,tostring(data.intent_hand)))
                elseif kind=="trajectory_selected" then
                    event(kind,string.format("action=%s kind=%s score=%s mirrored=%s interval=%s",
                        tostring(data.action),tostring(data.kind),tostring(data.score),tostring(data.mirrored),tostring(data.interval)),run.id)
                elseif kind=="trajectory_rejected" then
                    run.physical_failure=data.reason
                    event(kind,"reason="..tostring(data.reason),run.id)
                elseif kind=="context" then
                    if not data.accepted then run.physical_failure=data.reason end
                    event("physical_context",string.format("accepted=%s reason=%s action=%s simulation_t=%s start_t=%s authored_start=%s scale=%s lightning=%s special_at_start=%s",
                        tostring(data.accepted),tostring(data.reason),tostring(data.action),tostring(data.time),
                        tostring(data.start_time),tostring(data.authored_start),tostring(data.scale),tostring(data.lightning),tostring(data.special_at_start)))
                elseif kind=="availability" then
                    if data.reason then event("physical_unavailable",data.reason) end
                elseif kind=="query_rejected" then event("physical_query_rejected",data.reason)
                elseif kind=="invalidate" then
                    if state.run==run and (data.reason=="world_discontinuity" or tostring(data.reason):match("^sticky_")) then
                        run.abort_reason="runtime_"..tostring(data.reason)
                    end
                elseif kind=="push" then event("push_requested","source="..data.source.." authority="..data.authority)
                elseif kind=="charge_start" or kind=="charge_cancel" or kind=="followup_cancel" or kind=="followup_unavailable" then
                    event(kind,"action="..tostring(data.action).." reason="..tostring(data.reason))
                elseif kind=="sticky_constraint" then event(kind,"target="..data.target.." node="..tostring(data.node).." frame="..tostring(data.frame))
                elseif kind=="sticky_release" then event(kind,string.format("reason=%s requested_raw_distance=%s requested_raw_angle=%s requested_virtual_distance=%s requested_virtual_angle=%s",
                    tostring(data.reason),tostring(data.raw_distance),tostring(data.raw_angle),tostring(data.virtual_distance),tostring(data.virtual_angle)))
                elseif kind=="native_lifecycle" then
                    local key=(data.event=="_exit_damage_window" and "exit_" or "proc_")..data.stage
                    run[key]=(run[key] or 0)+1
                    event(kind,string.format("event=%s stage=%s action=%s simulation_t=%s frame=%s",
                        data.event,data.stage,tostring(data.action),tostring(data.time),tostring(run.frame)),run.id)
                elseif kind=="native_finish_error" or kind=="native_cancel_error" or kind=="native_query_error" or kind=="sticky_constraint_error" then
                    run.physical_failure=data.reason; event(kind,data.reason,run.id)
                end
            end})
    else
        state.run.LeaseApi=Lease; state.run.lease={source="synthetic_baseline"}
        Lease.claim_source(p.player_unit,state.run.lease)
    end
    event("start",string.format("source=%s config=poly131_%08x duration_scale=%.6f keys=%d target=%s generation=%d weight=%s weapon=%s mode=desktop pose_source=synthetic_body_local clock=simulation seed=unavailable damage=%s pose_schema=2 debug=orange_raw,cyan_virtual,red_contact anchor=%s anchor_rotation=initial_camera",
        name,checksum,scale,#keys,state.target_id,state.target_generation,profile or "raw",tostring(weapon.weapon_template.name),
        physical and "physical_local_prototype" or "stock_window",anchor_mode))
end
local inventory_catalog=mod:io_dofile("darktide_testlab/scripts/mods/darktide_testlab/inventory").new({
    context=function()
        assert(local_range(),"local Psykhanium required")
        local p=assert(player(),"player unavailable")
        return {unit=p.player_unit,character=p:character_id(),session=Managers.state.game_session}
    end,
    same_context=function(context)
        local p=player()
        return local_range() and p and p.player_unit==context.unit and p:character_id()==context.character and
            Managers.state.game_session==context.session
    end,
    fetch=function(context) return Managers.data_service.gear:fetch_inventory(context.character,{"slot_primary","slot_secondary"}) end,
    describe=function(gear_id,item)
        local template=WeaponTemplate.weapon_template_from_item(item)
        local sticky,lightning,delayed=0,0,0
        for _,settings in pairs(template.actions or {}) do
            if settings.kind=="sweep" then
                if settings.hit_stickyness_settings or settings.hit_stickyness_settings_special_active then sticky=sticky+1 end
                if settings.weapon_chain_lightning_template then lightning=lightning+1 end
                if (settings.num_frames_before_process or 0)>0 then delayed=delayed+1 end
            end
        end
        return string.format("gear_id=%s template=%s item=%s slots=%s sticky_actions=%d lightning_actions=%d delayed_actions=%d",
            tostring(gear_id),tostring(template.name),tostring(item.name),table.concat(item.slots or {},","),sticky,lightning,delayed)
    end,
    emit=function(id,kind,detail) event(kind,detail,id) end,
})
local function same_weapon_owner(context)
    local p=player()
    return local_range() and p and p.player_unit==context.unit and p:character_id()==context.character and
        Managers.state.game_session==context.session
end
temporary_weapon=mod:io_dofile("darktide_testlab/scripts/mods/darktide_testlab/loadout").new({
    context=function()
        assert(#state.pinned_loaders<16,"temporary_weapon_session_limit_restart_required")
        assert(local_range(),"local Psykhanium required")
        local p=assert(player(),"player unavailable")
        local extension=ScriptUnit.extension(p.player_unit,"weapon_system")
        local slot=extension._inventory_component.wielded_slot
        assert(slot=="slot_primary" or slot=="slot_secondary","wield a weapon before temporary equip")
        local visual=ScriptUnit.extension(p.player_unit,"visual_loadout_system")
        local profile=p:profile()
        return {unit=p.player_unit,character=p:character_id(),session=Managers.state.game_session,
            slot=slot,original=visual:item_in_slot(slot),profile=profile,profile_item=profile.loadout[slot],
            profile_primary=profile.loadout.slot_primary,profile_secondary=profile.loadout.slot_secondary,
            equipment=visual._equipment,static_properties=visual._static_profile_properties}
    end,
    current=same_weapon_owner,
    gone=function(context) return not Unit.alive(context.unit) end,
    clock=function() return state.clock end,
    eligible=function(context,item)
        local archetype=context.profile.archetype
        local function allows(list,value)
            if not list then return true end
            for _,entry in ipairs(list) do if entry==value then return true end end
            return false
        end
        if not allows(item.breeds,archetype.breed) or not allows(item.archetypes,archetype.name) then return false end
        if not item.slots or not allows(item.slots,context.slot) or not item.gear_id then return false end
        local template=WeaponTemplate.weapon_template_from_item(item)
        for _,action in pairs(template.actions or {}) do
            if context.slot=="slot_primary" and action.kind=="sweep" then return true end
            if context.slot=="slot_secondary" and (action.kind=="shoot_hit_scan" or action.kind=="shoot_pellets" or
                action.kind=="shoot_projectile" or action.kind=="flamer_gas" or action.kind=="flamer_gas_burst") then return true end
        end
        return false
    end,
    loader=function(context)
        local native=ProfilePackages:new("darktide_testlab_"..tostring(context.unit),MasterItems.get_cached())
        local resources=mod:io_dofile("darktide_testlab/scripts/mods/darktide_testlab/resources")
        return {
            load_slot_item=function(_,slot,item)
                local proxy=resources.item(item,context,{properties=EquipmentComponent.resolve_profile_properties,
                    particles=PlayerParticles.find_relevant_particles,sounds=PlayerSounds.find_relevant_events,
                    decals=PlayerDecals.find_relevant_decals})
                local count=0;for _ in pairs(proxy.resource_dependencies) do count=count+1 end
                event("weapon_packages","slot="..slot.." resources="..count.." profile_fx=true",state.weapon_request)
                native:load_slot_item(slot,proxy)
            end,
            is_slot_loaded=function(_,...) return native:is_slot_loaded(...) end,
            destroy=function() return native:destroy() end,
        }
    end,
    -- Live engine validation found shared animation resources still referenced
    -- after native re-equip. Keep our package refs until process shutdown;
    -- releasing an apparently unused preview package can crash has_unloaded.
    retire_loader=function(loader)
        state.pinned_loaders[#state.pinned_loaders+1]=loader
        event("weapon_packages_retained","scope=process reason=shared_animation_lifetime count="..#state.pinned_loaders,state.weapon_request)
    end,
    equip=function(context,item)
        assert(same_weapon_owner(context),"temporary_weapon_owner_changed")
        assert(cleanup("temporary_weapon_change"),"threat_restoration_pending")
        VisualLoadout.equip_item_to_slot(context.unit,item,context.slot,nil,Managers.time:time("gameplay"))
        assert(context.profile.loadout.slot_primary==context.profile_primary and
            context.profile.loadout.slot_secondary==context.profile_secondary,"persistent_profile_item_changed")
    end,
    equipped=function(context,item)
        local extension=ScriptUnit.has_extension(context.unit,"weapon_system")
        local actual=extension and extension._weapons and extension._weapons[context.slot]
        return actual and actual.item and actual.item.gear_id==item.gear_id and actual.item.name==item.name and
            extension._inventory_component.wielded_slot==context.slot
    end,
    emit=function(kind,data) event(kind,"phase="..data.phase.." reason="..tostring(data.reason),state.weapon_request) end,
})
local function start_manual_combat()
    if not isolation.ready() then return end
    state.manual_sequence=(state.manual_sequence or 0)+1
    local id="manual_combat_"..state.manual_sequence
    event("combat_range_isolated","native_retirement_complete",id)
    local context=assert(target_context(),"player unavailable")
    state.manual={unit=context.unit,session=context.session,run=id,manual=true}
    state.manual_pending=nil
    state.empty_combat=true
    event("combat_empty_ready","manual_spawn_required=true owned_targets="..#targets.entries(),id)
    if mod.echo then mod:echo("Combat on: empty arena. Tap both stick clicks to spawn one poxwalker; hold both to stop.") end
end
mod.spawn_combat_enemy=function()
    local ok,err=pcall(function()
        assert(local_range() and state.manual and isolation.active() and isolation.ready(),"start combat mode first")
        assert(threat.status()=="idle","finish the current attacker first")
        assert(not state.target or not Unit.alive(state.target) or health(state.target)<=0,"finish the current target first")
        spawn("chaos_poxwalker",2,state.manual.run,1,nil,true)
        threat.begin(120,state.manual.run)
        event("combat_manual_spawn","breed=chaos_poxwalker count=1",state.manual.run)
    end)
    if not ok then event("combat_spawn_error",err);if mod.echo then mod:echo(tostring(err)) end end
    return ok,err
end
mod.toggle_combat=function()
    state.auto_combat=false
    local ok,err=pcall(function()
        assert(local_range(),"local Psykhanium required")
        assert(not state.run,"stop scripted replay before manual combat")
        if state.manual or state.manual_pending or isolation.active() or threat.status()~="idle" then
            assert(cleanup("manual_combat_off"),"combat_restoration_pending")
            if mod.echo then mod:echo("Combat off: restoring normal training enemies.") end
            return
        end
        assert(cleanup("manual_combat_start"),"combat_restoration_pending");despawn()
        isolation.begin(true) -- never mass-retire an already populated normal room
        state.manual_pending=true
        start_manual_combat()
    end)
    if not ok then
        if state.combat_range_profile then state.restore_combat_range=true end
        cleanup("manual_combat_error");event("manual_combat_error",err);if mod.echo then mod:echo(tostring(err)) end
    end
end
local combat_controls=mod:io_dofile("darktide_testlab/scripts/mods/darktide_testlab/combat_controls").new(mod.toggle_combat,function()
    return local_range() and not state.run and (not mod.get or mod:get("testlab_controller_chord")~=false)
end,function() if state.manual then mod.spawn_combat_enemy() end end)
mod.controller_input=function(held,active,t)
    state.controller_ready_at=active and state.clock or nil
    return combat_controls.sample(held,active,t)
end
local function command(text)
    if not text then return end
    local id,verb,args=text:match("^([%w_-]+)%s+(%w+)%s*(.-)%s*$")
    if not id or id==state.last_id then return end
    state.last_id=id
    local ok,err=pcall(function()
        if verb=="spawn" then
            assert(cleanup("spawn"),"threat_restoration_pending"); local breed,distance=args:match("^([%w_]+)%s+([%d.]+)$"); spawn(breed,tonumber(distance),id)
        elseif verb=="attacker" then
            assert(cleanup("spawn_attacker"),"threat_restoration_pending")
            assert(args:match("^[%d.]+$"),"attacker requires distance 0.8..4")
            spawn("chaos_poxwalker",tonumber(args),id,1,nil,true)
        elseif verb=="group" then
            assert(cleanup("spawn"),"threat_restoration_pending")
            local breed,count,distance,spacing=args:match("^([%w_]+)%s+(%d+)%s+([%d.]+)%s+([%d.]+)$")
            spawn(breed,tonumber(distance),id,tonumber(count),tonumber(spacing))
        elseif verb=="run" then run_case(id,args)
        elseif verb=="threat" then
            assert(args:match("^[%d.]+$"),"threat requires duration seconds 1..12")
            threat.begin(tonumber(args),id)
        elseif verb=="stop" then cleanup("command"); state.stage="idle"; state.startup=nil
        elseif verb=="reset" then cleanup("reset"); despawn()
        elseif verb=="recenter" then
            if threat.status()~="idle" then assert(cleanup("recenter"),"threat_restoration_pending");return end
            local run=assert(state.run,"no active replay")
            cancel_native(run)
            run.reference={}; run.pose_reference={}
            if run.strokes then run.strokes.invalidate() end
            event("reference_reset","source=synthetic debt_remaining="..tostring(run.strokes and run.strokes.status().remaining))
        elseif verb=="inventory" then
            assert(args=="","inventory takes no arguments")
            inventory_catalog.fetch(id)
        elseif verb=="aimcheck" then
            assert(local_range(),"local Psykhanium required")
            local count=tonumber(args)
            local vr=get_mod("darktidevr")
            assert(vr and vr.request_crosshair_check,"VR crosshair observer unavailable")
            vr.request_crosshair_check(assert(player(),"player unavailable").player_unit,count)
            event("crosshair_check_requested","samples="..tostring(count),id)
        elseif verb=="weapon" then
            if args=="restore" then
                state.weapon_request=id
                assert(temporary_weapon.restore("command"),"weapon_restoration_pending")
            else
                assert(temporary_weapon.status()=="idle","temporary_weapon_busy")
                assert(args:match("^[%w_-]+$"),"weapon requires an owned gear ID or restore")
                local item=assert(inventory_catalog.lookup(args),"fetch owned inventory before choosing a gear ID")
                state.weapon_request=id
                temporary_weapon.begin(item)
            end
        elseif verb=="combat" then
            assert(local_range(),"local Psykhanium required")
            assert(args=="on" or args=="off" or args=="spawn","combat requires on, off or spawn")
            if args=="spawn" then assert(mod.spawn_combat_enemy());return end
            local enabled=state.manual~=nil or state.manual_pending==true or isolation.active() or threat.status()~="idle"
            if (args=="on")~=enabled then mod.toggle_combat() end
            event("combat_request","desired="..args)
        elseif verb=="status" then
            local p=player()
            local extension=p and p.player_unit and ScriptUnit.has_extension(p.player_unit,"weapon_system")
            local component=extension and extension._weapon_action_component
            local primary=extension and extension._weapons and extension._weapons.slot_primary
            local item=primary and primary.item
            local profile_item=p and p:profile().loadout.slot_primary
            local secondary=extension and extension._weapons and extension._weapons.slot_secondary
            local secondary_item=secondary and secondary.item
            local secondary_profile=p and p:profile().loadout.slot_secondary
            event("status","stage="..state.stage.." health="..health(state.target)..
                " action="..tostring(component and component.current_action_name).." gear_id="..tostring(item and item.gear_id)..
                " template="..tostring(primary and primary.weapon_template.name).." profile_gear_id="..tostring(profile_item and profile_item.gear_id)..
                " temporary="..temporary_weapon.status().." wielded_slot="..tostring(extension and extension._inventory_component.wielded_slot)..
                " secondary_gear_id="..tostring(secondary_item and secondary_item.gear_id)..
                " secondary_template="..tostring(secondary and secondary.weapon_template.name)..
                " secondary_profile_gear_id="..tostring(secondary_profile and secondary_profile.gear_id)..
                " combat="..tostring(state.manual~=nil or state.manual_pending==true)..
                " native_minions="..tostring(Managers.state and Managers.state.minion_spawn and Managers.state.minion_spawn._spawned_minions and #Managers.state.minion_spawn._spawned_minions or -1)..
                " owned_targets="..#targets.entries().." threat="..threat.status(),id)
        elseif verb=="buffs" then
            assert(args=="","buffs takes no arguments")
            local context=assert(target_context(),"local Psykhanium required")
            assert(context.unit and Unit.alive(context.unit),"player unavailable")
            local extension=assert(ScriptUnit.has_extension(context.unit,"buff_system"),"native buff extension unavailable")
            capture_buffs(context,extension,"manual",id,Managers.time:time("gameplay"),nil)
        elseif verb=="reload" then
            assert(not state.range_profile,"isolated_range_profile_requires_process_restart")
            assert(temporary_weapon.restore("reload"),"weapon_restoration_pending")
            assert(#state.pinned_loaders==0,"temporary_packages_require_process_restart")
            assert(cleanup("reload"),"threat_restoration_pending");get_mod("DMF").request_mod_reload()
        elseif verb=="enter" then
            assert(temporary_weapon.restore("enter"),"weapon_restoration_pending")
            assert(cleanup("enter"),"threat_restoration_pending")
            local character=args:match("^(.-)%s*%-%-empty%-range$")
            if character then
                assert(not local_range(),"empty range must be armed before entering Psykhanium")
                local creature=assert(get_mod("creature_spawner"),"creature_spawner_unavailable")
                local settings=assert(creature.settings,"creature_settings_unavailable")
                if not state.range_profile then state.range_profile={settings=settings,respawn=settings.cs_enable_training_grounds_respawn} end
                settings.cs_enable_training_grounds_respawn=false
                event("range_profile_armed","default_respawn=false original="..tostring(state.range_profile.respawn),id)
                args=character:gsub("%s+$","")
            end
            state.stage="enter"; state.stage_t=state.clock
            state.startup={armed=true,character=args~="" and args or nil}
        elseif verb=="quit" then assert(temporary_weapon.restore("quit"),"weapon_restoration_pending");assert(cleanup("quit"),"threat_restoration_pending");restore_range_profile("quit"); Application.quit()
        else error("unknown_command") end
    end)
    write("ack.tsv",id.."\t"..(ok and "accepted" or "error").."\t"..tostring(err or verb).."\n")
    if not ok then cleanup("command_error"); event("error",err) end
end
-- Acknowledged requests are not replayed when the mod is hot-reloaded.
state.last_id=(file_read("ack.tsv") or ""):match("^([%w_-]+)\t")
mod:hook_safe("TitleView","update",function(self,dt,t,input)
    if state.stage=="enter" and state.startup and Startup.title(state.startup,self,input,t) then
        event("startup","title_continue")
    end
end)
mod:hook_safe("MainMenuView","update",function(self,dt,t,input)
    if state.stage~="enter" or not state.startup then return end
    if Startup.character(state.startup,self,input,Managers.ui,t) then event("startup","character_start") end
    if state.startup.failed then state.stage="error"; event("error",state.startup.failed) end
end)

-- Both the desktop producer and real tracking use the canonical combat owner.
mod:hook_safe(Sweep,"start",function(self,settings,t)
    local run=state.run
    if not run or not run.runtime or self._player_unit~=run.unit or not local_range() then return end
    if run.runtime.on_start(self,settings,t) then state.suppressed[self]=run.runtime end
    run.physical_action=run.runtime.current_action()
end)
mod:hook(Sweep,"_update_sweep",function(func,self,dt,t,in_action,settings)
    local runtime=state.suppressed[self]
    if not runtime then return func(self,dt,t,in_action,settings) end
    if not local_range() then runtime.invalidate("context_changed"); return end
    runtime.update_sweep(self,dt,t,settings)
end)
local function packed(...) return {n=select("#",...),...} end
mod:hook("GameModeManager","should_disable_minion_perception",function(func,self,...)
    local disabled=func(self,...)
    if state.native_attacker_spawn and self==Managers.state.game_mode and local_range() then
        state.spawn_ai_gate_reads=state.spawn_ai_gate_reads+1
        return false -- only the native initializer of this owned poxwalker
    end
    return disabled
end)
mod:hook(Attack,"execute",function(func,target,profile,...)
    local run=state.run
    if not run or not local_range() or Managers.state.game_session~=run.session or
            (target~=run.unit and not targets.owns(target)) then return func(target,profile,...) end
    return observations.attack(func,run,target,profile,...)
end)
local function observe_proc(func,self,kind,params,...)
    local run=state.run
    if not run or not local_range() or Managers.state.game_session~=run.session or
            (self._unit~=run.unit and not targets.owns(self._unit)) then return func(self,kind,params,...) end
    return observations.proc(func,run,self,kind,params,...)
end
-- Fatshark class() copies inherited methods. A concrete class created before
-- the delayed base hook otherwise retains an unobserved native function.
mod:hook("BuffExtensionBase","add_proc_event",observe_proc)
mod:hook("PlayerUnitBuffExtension","add_proc_event",observe_proc)
mod:hook("MinionBuffExtension","add_proc_event",observe_proc)
mod:hook_safe("PlayerUnitBuffExtension","fixed_update",function(self,unit,dt,t,frame)
    local run=state.run
    if not run or unit~=run.unit or self._unit~=run.unit or not local_range() or Managers.state.game_session~=run.session then return end
    if not run.buff_snapshot_started or (run.buff_snapshot_pending and t>=(run.next_buff_snapshot_t or -math.huge)) then
        local phase=run.buff_snapshot_started and "post_proc" or "begin"
        if capture_buffs(run,self,phase,run.id,t,frame) then
            run.buff_snapshot_started=true;run.buff_snapshot_pending=false;run.next_buff_snapshot_t=t+.25
        end
    end
end)
mod:hook_require("scripts/settings/buff/buff_classes",function(classes)
    for _,class in pairs(classes) do
        if type(class)=="table" and type(class.update_proc_events)=="function" and not state.buff_proc_classes[class] then
            state.buff_proc_classes[class]=true
            mod:hook(class,"update_proc_events",function(func,self,t,events,count,random,local_random,...)
                local run=state.run
                if not run or not local_range() or Managers.state.game_session~=run.session or
                        (self._unit~=run.unit and not targets.owns(self._unit)) then
                    return func(self,t,events,count,random,local_random,...)
                end
                return observations.buff_proc(func,run,self,t,events,count,random,local_random,...)
            end)
        end
    end
end)
mod:hook(Sweep,"finish",function(func,self,reason,data,t,...)
    local runtime=state.suppressed[self]
    local before,err=true
    if runtime then before,err=pcall(runtime.on_finish,self,t) end
    local result=packed(pcall(func,self,reason,data,t,...))
    local observed=state.live_contacts[self]
    if observed then
        pcall(event,"live_contact_summary",string.format("action=%s queries=%d raw_actors=%d owned_actors=%d selected=%d hit_callbacks=%d damage_calls=%d reason=%s",
            tostring(self._weapon_action_component and self._weapon_action_component.current_action_name),observed.queries,observed.contacts,
            observed.owned,observed.selections,observed.hits,observed.damage_calls,tostring(reason)),observed.id)
        state.live_contacts[self]=nil
    end
    local after,after_err=true
    if runtime then after,after_err=pcall(runtime.after_finish,self);state.suppressed[self]=nil end
    if not before then error(err,0) end
    if not result[1] then error(result[2],0) end
    if not after then error(after_err,0) end
    return unpack(result,2,result.n)
end)
for _,name in ipairs({"_exit_damage_window","_handle_exit_procs"}) do
    mod:hook(Sweep,name,function(func,self,...)
        local runtime=state.suppressed[self]
        if runtime and runtime.native_event(self,name,func,...) then return end
        return func(self,...)
    end)
end
mod:hook(Sweep,"_start_hit_stickyness",function(func,self,settings,t,direction,...)
    local runtime=state.suppressed[self]
    if runtime then direction=runtime.world_direction(self) or direction end
    return func(self,settings,t,direction,...)
end)
mod:hook(Sweep,"_update_hit_stickyness",function(func,self,dt,t,component,settings,...)
    local run=state.run
    local held=component.sweep_aborted_unit or run and #(run.targets or {})==1 and run.target
    local owned=run and targets.find(run.targets,held)
    if not run or not state.suppressed[self] or not local_range() or Managers.state.game_session~=run.session or
            not owned or not owned.unit or not Unit.alive(owned.unit) then return func(self,dt,t,component,settings,...) end
    local before=health(owned.unit)
    local result=packed(func(self,dt,t,component,settings,...))
    local after=owned.unit and Unit.alive(owned.unit) and health(owned.unit) or -1
    local valid=before>=0 and after>=0
    if valid then
        owned.confirmed_zero=owned.confirmed_zero or after==0
        if owned.id==run.target_id then run.after=after;run.confirmed_zero=run.confirmed_zero or after==0 end
    end
    event("sticky_native_update",string.format("simulation_t=%.6f frame=%s target=%s generation=%s before=%.5f after=%.5f health_delta=%.5f health_valid=%s sticky=%s character_state=%s",
        t,tostring(run.frame),owned.id,tostring(owned.generation),before,after,valid and before-after or -1,tostring(valid),
        tostring(component.is_sticky),tostring(self._character_state_component and self._character_state_component.state_name)),run.id)
    return unpack(result,1,result.n)
end)
-- Baseline runs retain stock windows. The local physical prototype above
-- schedules the same native queries from committed motion instead.
mod:hook(Sweep,"_do_overlap",function(func,self,t,a,ar,b,br,final,settings,index)
    local run=state.run
    if not run or not local_range() or self._player_unit~=run.unit or self._unit_data_extension.is_resimulating then
        return func(self,t,a,ar,b,br,final,settings,index)
    end
    local sample_t=elapsed(run)
    local previous=run.action==self and run.last_sweep_t or sample_t
    if sample_t-previous>.1 or sample_t<previous then previous=sample_t end
    if run.weighted and not run.weighted.at(previous) then previous=sample_t end
    local ap,aq,bp,bq=a,ar,b,br
    if not run.physical then ap,aq=pose(run,"right",previous); bp,bq=pose(run,"right",sample_t) end
    run.action=self; run.last_sweep_t=sample_t; run.sweeps=run.sweeps+1
    if run.observed_query_frame~=run.frame then
        run.observed_query_frame=run.frame
        target_state(run,"sweep")
        local box=settings.weapon_box or self._weapon_template and self._weapon_template.weapon_box or run.weapon.weapon_template.weapon_box
        if box then
            local x,y,z,w=Quaternion.to_elements(bq)
            event("query_geometry",string.format("action=%s matrix=%s box=%.5f,%.5f,%.5f width_mod=%s height_mod=%s range_mod=%s rotation=%.6f,%.6f,%.6f,%.6f",
                tostring(self._weapon_action_component.current_action_name),tostring(self._uses_matrix_data),box[1],box[2],box[3],
                tostring(settings.width_mod or 1),tostring(settings.height_mod or 1),tostring(settings.range_mod or 1),x,y,z,w))
        end
    end
    event("sweep",string.format("action=%s scale=%.4f sample=%.6f from=%.4f,%.4f,%.4f to=%.4f,%.4f,%.4f",
        tostring(self._weapon_action_component.current_action_name),self._weapon_action_component.time_scale or 1,
        sample_t,Vector3.x(ap),Vector3.y(ap),Vector3.z(ap),Vector3.x(bp),Vector3.y(bp),Vector3.z(bp)))
    local clock=Mods.lua.os and Mods.lua.os.clock
    local begin=clock and clock()
    local result=func(self,t,ap,aq,bp,bq,final,settings,index)
    if begin then
        local cost=clock()-begin
        run.query_cpu_seconds=(run.query_cpu_seconds or 0)+cost
        run.max_query_cpu_seconds=math.max(run.max_query_cpu_seconds or 0,cost)
        event("query_cost",string.format("cpu_seconds=%.9f frame=%s",cost,tostring(run.frame)))
    end
    return result
end)
-- Observe native broad contacts and native selection separately. Preserve the
-- exact reused engine tables and return values; diagnostics never admit hits.
local function observe_contacts(kind,func,self,...)
    local live=live_contact_observation(self)
    if live and live.queries==0 and kind=="box" then
        local a,ar,b,br=...
        local x,y,z,w=Quaternion.to_elements(br)
        local box=self._action_settings and self._action_settings.weapon_box or self._weapon_template and self._weapon_template.weapon_box or {}
        local target=state.target and Unit.alive(state.target) and Unit.world_position(state.target,1)
        event("live_query_geometry",string.format("start=%.4f,%.4f,%.4f end=%.4f,%.4f,%.4f rotation=%.5f,%.5f,%.5f,%.5f box=%s,%s,%s target=%s",
            Vector3.x(a),Vector3.y(a),Vector3.z(a),Vector3.x(b),Vector3.y(b),Vector3.z(b),x,y,z,w,
            tostring(box[1]),tostring(box[2]),tostring(box[3]),
            target and string.format("%.4f,%.4f,%.4f",Vector3.x(target),Vector3.y(target),Vector3.z(target)) or "none"),live.id)
    end
    local results,count=func(self,...)
    local run=state.run
    if live then
        local owned=0
        for i=1,math.min(count or 0,32) do
            local actor=results[i].actor
            if actor and targets.owns(Actor.unit(actor)) then owned=owned+1 end
        end
        live.queries=live.queries+1;live.contacts=live.contacts+(count or 0);live.owned=live.owned+owned
        if live.queries==1 or owned>0 and not live.logged_owned then
            if owned>0 then live.logged_owned=true end
            event("live_query_contacts",string.format("kind=%s actors=%s owned_target_actors=%d matrix=%s filter=%s",
                kind,tostring(count),owned,tostring(self._uses_matrix_data),tostring(self._collision_filter)),live.id)
        end
    end
    if run and self._player_unit==run.unit and local_range() then
        local owned=0
        for i=1,count or 0 do
            local actor=results[i].actor
            if actor and targets.owns(Actor.unit(actor)) then owned=owned+1 end
        end
        event("query_contacts",string.format("kind=%s frame=%s actors=%s owned_target_actors=%d",kind,tostring(run.frame),tostring(count),owned))
    end
    return results,count
end
mod:hook(Sweep,"_run_sweeps",function(func,self,...) return observe_contacts("box",func,self,...) end)
mod:hook(Sweep,"_run_sphere_sweeps",function(func,self,...) return observe_contacts("sphere",func,self,...) end)
mod:hook(Sweep,"_pick_best_sweep_result_per_unit",function(func,self,results,count,hit_units,...)
    local best,actor_to_unit=func(self,results,count,hit_units,...)
    local run=state.run
    local live=live_contact_observation(self)
    if live then
        local selected=0;for _ in pairs(best) do selected=selected+1 end
        live.selections=live.selections+selected
        if (count or 0)>0 and (live.selection_logs or 0)<3 then
            live.selection_logs=(live.selection_logs or 0)+1
            local in_view="unobserved"
            for i=1,math.min(count,32) do
                local actor=results[i].actor
                if actor and targets.owns(Actor.unit(actor)) and self._first_person_extension then
                    local ok,value=pcall(self._first_person_extension.is_within_default_view,self._first_person_extension,results[i].position)
                    in_view=ok and tostring(value) or "query_error"
                end
            end
            event("live_sweep_selection",string.format("raw_actors=%d selected=%d owned_in_view=%s",count,selected,in_view),live.id)
        end
    end
    if run and self._player_unit==run.unit and local_range() then
        local owned,in_view=0,"unobserved"
        for i=1,count do
            local result=results[i]
            if result.actor and targets.owns(Actor.unit(result.actor)) then
                owned=owned+1
                local fp=self._first_person_extension
                if fp and fp.is_within_default_view then
                    local ok,value=pcall(fp.is_within_default_view,fp,result.position)
                    in_view=ok and tostring(value) or "query_error"
                end
            end
        end
        local selected,already=0,0
        for _,entry in ipairs(targets.entries()) do
            if entry.unit and best[entry.unit] then selected=selected+1 end
            if entry.unit and hit_units[entry.unit] then already=already+1 end
        end
        event("sweep_selection",string.format("frame=%s owned_target_actors=%d selected=%s already_hit=%s last_actor_in_view=%s owned_selected=%d owned_already_hit=%d",
            tostring(run.frame),owned,tostring(best[state.target]~=nil),tostring(hit_units[state.target]==true),in_view,selected,already))
    end
    return best,actor_to_unit
end)
mod:hook("ActionHandler","_validate_single_chain_action",function(func,self,chain,t,...)
    local run=state.run
    local selected=run and run.physical and local_range() and run.runtime.select_chain(self,chain,t,...) or chain
    local valid,name,settings,reset=func(self,selected,t,...)
    if valid and run and run.physical and local_range() and not run.runtime.allow_chain(self,chain,t) then valid=false end
    return valid,name,settings,reset
end)
mod:hook(Sweep,"_current_max_hit_mass",function(func,self,...)
    local values=packed(func(self,...))
    local run=state.run
    if run and self._player_unit==run.unit and local_range() and not self._unit_data_extension.is_resimulating then
        run.native_mass=run.native_mass or setmetatable({}, {__mode="k"})
        run.native_mass[self]=values[1]
    end
    return unpack(values,1,values.n)
end)
mod:hook(Sweep,"_process_hit",function(func,self,t,unit,actor,hits,settings,position,direction,zone,...)
    local run=state.run
    local live=live_contact_observation(self)
    local live_before=live and unit==state.target and health(unit)
    local owned=run and targets.find(run.targets,unit)
    local before_mass=self._amount_of_mass_hit
    if run and run.physical and self._player_unit==run.unit and
            not run.runtime.claim(self,unit) then return false,false end
    if run and run.runtime then
        local actual=run.runtime.world_direction(self)
        if actual then direction=actual end
    end
    local aborted,armor=func(self,t,unit,actor,hits,settings,position,direction,zone,...)
    if live then
        live.hits=live.hits+1
        if live.hits<=3 then event("live_hit_callback",string.format("owned=%s before=%s after=%s aborted=%s armor=%s",
            tostring(unit==state.target),tostring(live_before),tostring(unit==state.target and health(unit)),tostring(aborted),tostring(armor)),live.id) end
    end
    if run and self._player_unit==run.unit and not self._unit_data_extension.is_resimulating then
        if run.physical and run.weighted and run.weighted.latest() then
            local velocity=run.weighted.latest().linear_velocity
            local before=math.sqrt(velocity[1]^2+velocity[2]^2+velocity[3]^2)
            local reacted,retention=run.runtime.impact(aborted)
            if reacted then
                velocity=run.weighted.latest().linear_velocity
                local after=math.sqrt(velocity[1]^2+velocity[2]^2+velocity[3]^2)
                event("impact",string.format("retention=%.3f native_abort=%s linear_speed_before=%.6f linear_speed_after=%.6f",
                    retention,tostring(aborted),before,after))
            end
        end
        run.hits=run.hits+1
        if owned then
            owned.hits=owned.hits+1
            if owned.unit and Unit.alive(owned.unit) and health(owned.unit)==0 then owned.confirmed_zero=true end
        end
        local outcome=owned and targets.outcome(owned,target_context())
        if owned and owned.id==run.target_id and outcome.valid then
            run.after=outcome.after
            if outcome.after==0 then run.confirmed_zero=true end
        end
        if run.debug then run.debug.contact(position,elapsed(run)) end
        event("hit","owned_target="..tostring(owned~=nil).." target="..tostring(owned and owned.id).." zone="..tostring(zone).." health="..tostring(outcome and outcome.after or -1)..
            " action_time="..tostring(t-(self._weapon_action_component.start_t or t)))
        if owned then
            event("native_cleave",string.format("target=%s generation=%s mass_before=%s mass_after=%s max_mass=%s target_index=%s hit_count=%s aborted=%s armour_aborted=%s",
                owned.id,tostring(owned.generation),tostring(before_mass),tostring(self._amount_of_mass_hit),tostring(run.native_mass and run.native_mass[self]),
                tostring(self._target_index),tostring(self._num_hit_enemies),tostring(aborted),tostring(armor)))
        end
    end
    return aborted,armor
end)
mod:hook(Sweep,"_do_damage_to_unit",function(func,self,profile,target,...)
    local run=state.run
    local live=live_contact_observation(self)
    local owned=run and targets.find(run.targets,target)
    -- Capture ownership before native damage can destroy the unit/reference.
    local authoritative=run and owned and targets.owns(target) and local_range() and
        Managers.state.game_session==run.session and self._player_unit==run.unit and
        self._is_server==true and not self._unit_data_extension.is_resimulating
    local damage,result,efficiency,stagger,weakspot=func(self,profile,target,...)
    if live then
        live.damage_calls=live.damage_calls+1
        if live.damage_calls<=3 then event("live_native_damage",string.format("amount=%s result=%s owned=%s health=%s",
            tostring(damage),tostring(result),tostring(target==state.target),tostring(target==state.target and health(target))),live.id) end
    end
    if state.run==run and run and owned and self._player_unit==run.unit then
        if authoritative and result=="died" then
            owned.confirmed_native_kill=true
            if owned.id==run.target_id then run.confirmed_native_kill=true end
            event("native_target_killed","target="..owned.id.." generation="..tostring(owned.generation),run.id)
        end
        owned.native_damage=owned.native_damage+(tonumber(damage) or 0)
        if owned.id==run.target_id then run.native_damage=(run.native_damage or 0)+(tonumber(damage) or 0) end
        event("native_damage",string.format("amount=%s result=%s stagger=%s weakspot=%s critical=%s profile=%s seed=unavailable target=%s generation=%s",
            tostring(damage),tostring(result),tostring(stagger),tostring(weakspot),
            tostring(self._critical_strike_component and self._critical_strike_component.is_active),
            type(profile)=="table" and tostring(profile.name or "unnamed_native_profile") or tostring(profile),owned.id,tostring(owned.generation)))
    end
    return damage,result,efficiency,stagger,weakspot
end)
mod:hook_safe(Push,"_play_push_rumble",function(self,count)
    local run=state.run
    if run and local_range() and self._player_unit==run.unit and not self._unit_data_extension.is_resimulating then
        event("native_push_contacts","native_total_hits="..tostring(count).." per_target_stagger=unobserved")
    end
end)
mod:hook_safe(Push,"_push",function(self,t)
    local run=state.run
    if run and local_range() and self._player_unit==run.unit and not self._unit_data_extension.is_resimulating then
        event("native_push_complete","simulation_t="..tostring(t).." owned_target_health="..tostring(health(state.target)))
        target_state(run,"push_complete")
    end
end)
local function trace_tracking(run,frame,time,source,hand,pose)
    if not pose then return end
    local p,q=pose.position,pose.rotation
    local velocity={}
    for _,name in ipairs({"linear_velocity","angular_velocity"}) do
        for i=1,3 do velocity[#velocity+1]=pose[name] and string.format("%.6f",pose[name][i]) or "" end
    end
    write("tracking.tsv",string.format("%s\t%s\t%.6f\t%s\t%s\tbody\t%.6f\t%.6f\t%.6f\t%.6f\t%.6f\t%.6f\t%.6f\t%s\n",
        run.id,tostring(frame),time,source,hand,p[1],p[2],p[3],q[1],q[2],q[3],q[4],table.concat(velocity,"\t")),"a")
end
mod:hook(HumanInput,"fixed_update",function(func,self,dt,t,frame,input,...)
    local run=state.run
    if run and self._player==player() and local_range() then
        if run.abort_reason then cleanup(run.abort_reason);return func(self,dt,t,frame,input,...) end
        if not Unit.alive(run.unit) or player().player_unit~=run.unit or Managers.state.game_session~=run.session then
            cleanup("context_changed"); return func(self,dt,t,frame,input,...)
        end
        local inventory=ScriptUnit.extension(run.unit,"unit_data_system"):read_component("inventory")
        if inventory.wielded_slot~=run.slot or run.weapon_extension._weapons[run.slot]~=run.weapon then
            cleanup("weapon_changed"); return func(self,dt,t,frame,input,...)
        end
        if run.anchor_mode=="player" and run.anchor_frame~=frame then
            -- Native locomotion authors the player, never this harness. Follow
            -- only its translation, once per sim frame, retaining initial yaw.
            local delta=Unit.world_position(run.unit,1)-run.player_origin:unbox()
            local distance=Vector3.x(delta)^2+Vector3.y(delta)^2+Vector3.z(delta)^2
            if distance~=distance or distance>25 then
                cleanup("anchor_bounds");return func(self,dt,t,frame,input,...)
            end
            run.origin=Vector3Box(run.initial_origin:unbox()+delta);run.anchor_frame=frame
            event("anchor_frame",string.format("frame=%s mode=player_translation offset=%.6f,%.6f,%.6f distance=%.6f",
                tostring(frame),Vector3.x(delta),Vector3.y(delta),Vector3.z(delta),math.sqrt(distance)))
        end
        local sample,reason=Replay.advance(run.timeline,run.keys,t,frame)
        if not sample then cleanup(reason)
        else
            run.elapsed=sample.elapsed; run.frame=frame; run.last_step_wall=state.clock; run.simulation_t=t
            local virtual,detail=sample.right
            if run.runtime then
                local current
                current,detail=run.runtime.sample({source="synthetic",active=true,tracking_valid=true,
                    reference=run.reference,frame=frame,time=t,pose_time=sample.elapsed,dominant=sample.right,
                    support=sample.left,support_held=sample.buttons[3],intent=true,guarding=sample.buttons[2],followup_intent=sample.buttons[1],heavy_intent=run.heavy_enabled and sample.buttons[1]})
                if current then
                    virtual=current.pose; run.intent_offset=current.offset
                    run.physical_action=run.runtime.current_action()
                    local status,timing=current.stroke,current.timing
                    local key=status.phase..":"..tostring(timing and timing.ready)
                    if key~=run.motion_key then
                        run.motion_key=key
                        event("motion_state",string.format("phase=%s reason=%s native_ready=%s recovery=%.6f",
                            status.phase,status.reason,tostring(timing and timing.ready),status.recovery))
                    end
                else virtual=nil; cleanup("runtime_"..tostring(detail)) end
            elseif run.weighted then
                virtual,detail=run.weighted.update({dominant=sample.right,support=sample.left,
                    support_held=sample.buttons[3],time=sample.elapsed,frame=frame,reference=run.reference,
                    recovery=1,tracking_valid=true})
                if not virtual then cleanup("inertia_"..tostring(detail)) end
            end
            if run.weighted and virtual then
                if run.weight_frame~=frame then
                    run.weight_frame=frame
                    run.support_frames=(run.support_frames or 0)+(virtual.support_engaged and 1 or 0)
                    run.mass_min=math.min(run.mass_min or virtual.mass,virtual.mass)
                    run.mass_max=math.max(run.mass_max or virtual.mass,virtual.mass)
                end
                run.max_weight_lag=math.max(run.max_weight_lag or 0,virtual.position_lag)
                run.max_weight_angle=math.max(run.max_weight_angle or 0,virtual.angular_lag)
                event("weight",string.format("time=%.6f lag=%.6f angle=%.6f mass=%.6f support=%s reset=%s",
                    sample.elapsed,virtual.position_lag,virtual.angular_lag,virtual.mass,tostring(virtual.support_engaged),tostring(virtual.reset)))
            end            if virtual and state.run==run and run.trace_frame~=frame then
                run.trace_frame=frame
                trace_tracking(run,frame,sample.elapsed,"synthetic_raw","right",sample.right)
                trace_tracking(run,frame,sample.elapsed,"synthetic_raw","left",sample.left)
                trace_tracking(run,frame,sample.elapsed,run.weighted and "inertia_virtual" or "raw_passthrough","right",virtual)
                trace_tracking(run,frame,sample.elapsed,virtual.support and "inertia_support" or "free_support","left",virtual.support or sample.left)
            end
        end
    end
    return func(self,dt,t,frame,input,...)
end)
mod:hook_safe(HumanInput,"_parse_input",function(self,cache,input,index)
    local run=state.run
    if not run or self._player~=player() or not local_range() then return end
    local sample=run.timeline.sample
    if not sample then return end
    for _,binding in ipairs({{1,"action_one"},{2,"action_two"},{5,"weapon_extra"}}) do
        local edge=sample.inputs[binding[1]]
        if run.physical and binding[1]==1 then
            edge=run.runtime.inputs(run.frame)
        elseif run.physical and binding[1]==2 then
            edge=run.runtime.block_inputs(run.frame)
        end
        for suffix,value in pairs({_pressed=edge.pressed,_hold=edge.held,_release=edge.released}) do
            local action=self._action_lookup[binding[2]..suffix]
            if action then cache[action][index]=value end
        end
    end
    -- Dodge is a native ephemeral action, not an attack/hold binding.
    local dodge=self._action_lookup.dodge
    if dodge and cache[dodge] then cache[dodge][index]=sample.inputs[6].pressed end
end)
mod:hook_safe("PlayerUnitWeaponExtension","fixed_update",function(self,unit,dt,t,frame)
    local run=state.run
    if not run or self._unit~=run.unit or not local_range() then return end
    local component=self._weapon_action_component
    if not component then return end
    local stamina=-1
    local data=self._unit_data_extension
    if data then
        local ok,value=pcall(function() return data:read_component("stamina").current_fraction end)
        if ok and type(value)=="number" then stamina=value end
    end
    local blocking=false
    if data then
        local ok,value=pcall(function() return data:read_component("block").is_blocking end)
        blocking=ok and value==true
    end
    local fingerprint=string.format("action=%s scale=%.5f stamina=%.5f frame=%s blocking=%s",
        tostring(component.current_action_name),component.time_scale or 1,stamina,tostring(frame),tostring(blocking))
    local key=string.format("%s:%.5f:%.5f",tostring(component.current_action_name),component.time_scale or 1,stamina)..":"..tostring(blocking)
    if key~=run.native_state then run.native_state=key; event("native_state",fingerprint) end
end)
-- The later weighted/two-hand layer consumes these same replay inputs. Grip
-- channels are not falsely translated into an unrelated stock game button.
mod.replayed_hand=function(hand)
    local run=state.run
    if not run or not run.timeline.sample or (hand~="left" and hand~="right") then return nil end
    return run.timeline.sample[hand],run.timeline.sample.inputs[hand=="left" and 3 or 4]
end
local function inverse(q)
    local x,y,z,w=Quaternion.to_elements(q)
    return Quaternion.from_elements(-x,-y,-z,w)
end
local function place_node(unit,node,p,q)
    -- Derive parent transform from the current local/world poses. This works
    -- for linked weapon roots as well as bones, without unlinking game units.
    local parent=Unit.scene_graph_parent(unit,node)
    if node~=1 and parent and parent>=1 then
        local local_position=Matrix4x4.transform(Matrix4x4.inverse(Unit.world_pose(unit,parent)),p)
        local local_rotation=Quaternion.multiply(inverse(Unit.world_rotation(unit,parent)),q)
        Unit.set_local_position(unit,node,local_position)
        Unit.set_local_rotation(unit,node,local_rotation)
        return
    end
    local parent_rotation=Quaternion.multiply(Unit.world_rotation(unit,node),inverse(Unit.local_rotation(unit,node)))
    local parent_position=Unit.world_position(unit,node)-Quaternion.rotate(parent_rotation,Unit.local_position(unit,node))
    Unit.set_local_position(unit,node,Quaternion.rotate(inverse(parent_rotation),p-parent_position))
    Unit.set_local_rotation(unit,node,Quaternion.multiply(inverse(parent_rotation),q))
end
local function trace_pose(run,name,unit,node,requested,requested_rotation)
    local actual=Unit.world_position(unit,node)
    local q=Unit.world_rotation(unit,node)
    local x,y,z,w=Quaternion.to_elements(q)
    local delta=actual-requested
    local error=math.sqrt(Vector3.x(delta)^2+Vector3.y(delta)^2+Vector3.z(delta)^2)
    local rx,ry,rz,rw=Quaternion.to_elements(requested_rotation)
    local dot=math.min(1,math.abs(x*rx+y*ry+z*rz+w*rw))
    local angle=2*math.acos(dot)
    run.max_visual_error=math.max(run.max_visual_error or 0,error)
    run.max_angular_error=math.max(run.max_angular_error or 0,angle)
    if name=="weapon" then run.max_weapon_error=math.max(run.max_weapon_error or 0,error) end
    write("poses.tsv",string.format("%s\t%s\t%.6f\t%s\t%.6f\t%.6f\t%.6f\t%.6f\t%.6f\t%.6f\t%.6f\t%.6f\t%.6f\n",
        run.id,tostring(run.frame),elapsed(run),name,Vector3.x(actual),Vector3.y(actual),Vector3.z(actual),x,y,z,w,error,angle),"a")
end
-- Both authored wrists and the visible weapon receive replayed world poses.
-- This is a desktop test fixture, not a replacement for the VR arm solver.
mod:hook_safe("PlayerUnitVisualLoadoutExtension","post_update",function(self,unit,dt,t)
    local run=state.run
    if not run or not run.timeline.sample or (run.weighted and not run.weighted.latest()) or unit~=run.unit or not local_range() then return end
    local world=Managers.world:world("level_world")
    local arms=self._first_person_unit
    if arms and Unit.alive(arms) then
        for _,hand in ipairs({"left","right"}) do
            local name="j_"..hand.."hand"
            if Unit.has_node(arms,name) then
                local p,q=pose(run,hand,elapsed(run))
                place_node(arms,Unit.node(arms,name),p,q)
            end
        end
        World.update_unit_and_children(world,arms)
        if run.visual_frame~=run.frame then
            for _,hand in ipairs({"left","right"}) do
                local name="j_"..hand.."hand"
                if Unit.has_node(arms,name) then trace_pose(run,hand,arms,Unit.node(arms,name),pose(run,hand,elapsed(run))) end
            end
        end
    end
    local first=self:unit_and_attachments_from_slot(run.slot)
    local equipment=self._equipment and self._equipment[run.slot]
    local lookup=equipment and equipment.attachment_id_lookup_1p
    local selected={right=lookup and lookup.right or first,left=lookup and lookup.left}
    if selected.left==selected.right or selected.left==first then selected.left=nil end
    if not run.visual_inventory then
        run.visual_inventory=true
        local slot=self._equipment and self._equipment[run.slot]
        local attachments=slot and slot.attachment_id_lookup_1p
        event("visual_inventory","slot_root="..tostring(first).." native_weapon="..tostring(run.weapon.weapon_unit))
        event("visual_selected","dominant="..tostring(selected.right).." support="..tostring(selected.left))
        if type(attachments)=="table" then
            local count=0
            for id,attachment in pairs(attachments) do
                count=count+1; if count>32 then break end
                event("visual_attachment","id="..tostring(id).." unit="..tostring(attachment))
            end
        end
    end
    for _,hand in ipairs({"right","left"}) do
        local visual=selected[hand]
        if visual and Unit.alive(visual) then
        run.visual_originals=run.visual_originals or {}
        if not run.visual_originals[visual] then
            run.visual_originals[visual]={unit=visual,position=Vector3Box(Unit.local_position(visual,1)),
                rotation=QuaternionBox(Unit.local_rotation(visual,1))}
        end
        local p,q=pose(run,hand,elapsed(run))
        place_node(visual,1,p,q)
        World.update_unit_and_children(world,visual)
        -- Linked-root transforms can still contain the first frame's previous
        -- animated hand basis. Re-evaluate once after hierarchy propagation.
        local residual=Unit.world_position(visual,1)-p
        if Vector3.x(residual)^2+Vector3.y(residual)^2+Vector3.z(residual)^2>1e-6 then
            place_node(visual,1,p,q); World.update_unit_and_children(world,visual)
        end
        if run.visual_frame~=run.frame then trace_pose(run,hand=="right" and "weapon" or "offhand_weapon",visual,1,p,q) end
        run.samples=run.samples+1
        end
    end
    run.visual_frame=run.frame
    if run.debug then
        local ok,err=pcall(function()
            local hands={raw={},virtual={}}
            for _,hand in ipairs({"left","right"}) do
                local p,q=world_pose(run,run.timeline.sample[hand]); hands.raw[hand]={position=p,rotation=q}
                p,q=pose(run,hand,elapsed(run)); hands.virtual[hand]={position=p,rotation=q}
            end
            local volume
            if run.physical_action then
                volume=run.Volume.resolve(run.weapon.weapon_template,run.physical_action._action_settings,
                    run.defaults,run.physical_action._uses_matrix_data)
            end
            local eye=camera()
            if eye then run.debug.draw(world,eye,run.frame,elapsed(run),hands,run.intent_offset or {0,0,.3},volume) end
        end)
        if not ok then
            run.debug.destroy(); run.debug=nil; event("debug_error",err)
        end
    end
end)
local function update(dt)
    state.clock=state.clock+dt
    temporary_weapon.update()
    threat.update()
    if state.manual and (not local_range() or not Unit.alive(state.manual.unit) or Managers.state.game_session~=state.manual.session) then
        cleanup("manual_context_changed")
    end
    if state.manual_pending then
        local ok,err=pcall(start_manual_combat)
        if not ok then cleanup("manual_combat_error");event("manual_combat_error",err) end
    end
    if not state.manual and not state.manual_pending and threat.status()=="idle" and isolation.active() then isolation.restore("retry") end
    if state.restore_combat_range and not isolation.active() then
        restore_range_profile("combat_restore_retry")
        state.restore_combat_range=nil;state.combat_range_profile=nil
    end
    if state.auto_combat and local_range() and player() and player().player_unit then
        state.auto_combat_ready=state.auto_combat_ready or state.clock
        if state.clock-state.auto_combat_ready>=5 then
            state.auto_combat=false
            mod.toggle_combat()
        end
    elseif state.auto_combat then
        state.auto_combat_ready=nil
    end
    if state.run then
        local run=state.run
        if run.abort_reason then cleanup(run.abort_reason)
        elseif not local_range() or not Unit.alive(run.unit) or Managers.state.game_session~=run.session then cleanup("context_changed")
        elseif state.clock-run.last_step_wall>.5 then cleanup("simulation_stalled")
        else
            local inventory=ScriptUnit.extension(run.unit,"unit_data_system"):read_component("inventory")
            if inventory.wielded_slot~=run.slot or run.weapon_extension._weapons[run.slot]~=run.weapon then cleanup("weapon_changed")
            elseif elapsed(run)>run.keys[#run.keys].t+.8 then
                cleanup("complete")
            end
        end
    end
    if state.clock>=state.poll then state.poll=state.clock+.1; command(file_read("command.txt")) end
    if (state.stage=="enter" or state.stage=="loading_range") and state.clock-(state.stage_t or 0)>600 then
        state.stage="error"; event("error","startup_timeout"); return
    end
    if state.stage=="enter" and Managers.state and Managers.state.mission and
            Managers.state.game_mode and Managers.state.game_mode:game_mode_name()=="hub" and
            player() and player().player_unit and Unit.alive(player().player_unit) and
            Managers.ui and not Managers.ui:view_active("loading_view") then
        if state.vr_entry_owner then
            state.stage="loading_range";event("transition","waiting_for_VR_owned_Psykhanium_request");return
        end
        local Options=require("scripts/ui/views/training_grounds_options_view/training_grounds_options_view")
        -- Same transition as the training menu, with the normal single-player session.
        Options._start_training_grounds({_element=function() return nil end},{mission_name="tg_shooting_range"})
        state.stage="loading_range"; event("transition","tg_shooting_range")
    elseif state.stage=="loading_range" and local_range() then state.stage="ready"; event("ready","local Psykhanium") end
end
mod.update=function(dt)
    local ok,err=pcall(update,dt)
    if not ok then cleanup("update_error"); state.stage="error"; event("error",err) end
end
mod.on_game_state_changed=function(status,name)
    if status=="exit" and name=="StateGameplay" then temporary_weapon.restore("level_exit");inventory_catalog.cancel();cleanup("level_exit"); state.target=nil end
end
mod.on_unload=function() temporary_weapon.restore("unload");inventory_catalog.cancel();cleanup("unload"); despawn();restore_range_profile("unload") end
mod.on_setting_changed=function(name)
    if name=="testlab_controller_chord" and mod:get(name)==false then cleanup("combat_option_off") end
end
state.auto_combat=(file_read("combat_on_start.flag") or ""):match("^enabled%s*$")~=nil
state.empty_combat=state.auto_combat and not (Managers.state and Managers.state.game_session) or nil
-- Require hooks from other mods may replace step functions after ours.
-- Guard the final template immediately before the engine starts the step too.
mod:hook("ScriptedScenarioSystem","_start_step",function(func,self,scenario,step_template,player,scenario_data,step_data,t,...)
    if step_template and step_template.name then
        mod:io_dofile("darktide_testlab/scripts/mods/darktide_testlab/range_isolation").guard_defaults(
            {[step_template.name]=step_template},function() return state.empty_combat==true end,event)
    end
    return func(self,scenario,step_template,player,scenario_data,step_data,t,...)
end)
mod:hook_require("scripts/extension_systems/training_grounds/shooting_range_steps",function(steps)
    mod:io_dofile("darktide_testlab/scripts/mods/darktide_testlab/range_isolation").guard_defaults(steps,
        function() return state.empty_combat==true end,event)
end)
if state.auto_combat and not (Managers.state and Managers.state.game_session) then
    -- Suppress future default targets before the range loads, using the same
    -- reversible in-memory setting as --empty-range. Avoid loading then
    -- removing every training minion immediately before the first VR hit.
    local creature=get_mod("creature_spawner")
    if creature and creature.settings then
        local settings=creature.settings
        state.range_profile={settings=settings,respawn=settings.cs_enable_training_grounds_respawn}
        state.combat_range_profile=true
        settings.cs_enable_training_grounds_respawn=false
        event("range_profile_armed","source=combat_on_start default_respawn=false original="..tostring(state.range_profile.respawn))
    end
end
local vr_request=file_read("../darktidevr/darktidevr_enter_psykhanium.flag") or ""
local vr_entry=vr_request:match("^enter[%s\r\n]")~=nil or
    get_mod("darktidevr")~=nil and vr_request:match("^consumed%s*$")~=nil
if mod.get and mod:get("testlab_auto_enter")==true and not (Managers.state and Managers.state.game_session) then
    -- Do not publish an internal mailbox request: replacing the last ack here
    -- would replay an old quit/spawn request on the first update or reload.
    state.stage="enter";state.stage_t=state.clock
    state.vr_entry_owner=vr_entry
    state.startup={armed=true,character="Platforma"}
    event("startup_armed","source=mod_option character=Platforma")
end
event("loaded","testlab; mailbox=command.txt; VR combat shortcuts=tap both sticks to spawn; hold0.4s to toggle")
