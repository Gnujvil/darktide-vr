local root=assert(arg[1])
local Loadout=dofile(root..'/mods/darktide_testlab/scripts/mods/darktide_testlab/loadout.lua')
-- Execute the actual cached native package loader, including asynchronous
-- package references for both item instances. No game/equip result is claimed.
local env=setmetatable({}, {__index=_G})
env.table=setmetatable({clear=function(t) for k in pairs(t) do t[k]=nil end end,
    is_empty=function(t) return next(t)==nil end},{__index=table})
env.Script={new_map=function() return {} end,new_array=function() return {} end}
env.require=function() return {compile_item_instance_dependencies=function(item,_,result)
    for name in pairs(item.resource_dependencies) do result[name]=true end
end} end
env.class=function(name)
    local cls={}
    function cls:new(...) local obj=setmetatable({__class_name=name},{__index=cls});obj:init(...);return obj end
    return cls
end
env.callback=function(self,name,a,b,c,d) return function() return self[name](self,a,b,c,d) end end
local chunk=assert(loadfile(root..'/artifacts/game-reference/ui_character_profile_package_loader.lua'));setfenv(chunk,env)
local Native=chunk()
for _,mode in ipairs({'normal','package_timeout','equip_error','restore_error','context_change','owner_gone','verify_timeout','process_pin'}) do
    local original={gear_id='original',name='original_native_item',resource_dependencies={shared=true,original_model=true}}
    local candidate={gear_id='owned',name='candidate_native_item',resource_dependencies={shared=true,candidate_model=true}}
    local context={original=original}
    local time,valid,gone,equipped=0,true,false,original
    local loads,releases,calls,events={},{},{},{}
    env.Managers={package={load=function(_,package,reference,callback)
        local id=#loads+1;loads[id]={package=package,reference=reference,callback=callback};return id
    end,release=function(_,id)
        assert(not releases[id],'native package ref released twice');releases[id]=true
    end}}
    local pinned
    local api=Loadout.new({context=function() return context end,clock=function() return time end,
        retire_loader=mode=='process_pin' and function(loader) pinned=loader end or nil,
        current=function(ctx) assert(ctx==context);return valid end,gone=function() return gone end,
        eligible=function(_,item) return item==candidate end,
        loader=function() return Native:new('fixture',{}) end,
        equip=function(_,item)
            calls[#calls+1]=item
            if mode=='equip_error' and item==candidate then equipped=nil;error('native partial equip failure') end
            if mode=='restore_error' and item==original then error('native restore failure') end
            if mode~='verify_timeout' or item==original then equipped=item end
        end,
        equipped=function(_,item) return equipped==item end,
        emit=function(kind) events[#events+1]=kind end})
    api.begin(candidate);assert(api.status()=='loading' and #loads==4 and #calls==0)
    api.update();assert(#calls==0,'native equip ran before package callbacks')
    if mode=='package_timeout' then
        time=31;api.update();assert(api.status()=='idle' and #calls==0)
    else
        for _,load in ipairs(loads) do load.callback() end
        api.update()
        if mode=='equip_error' then
            assert(api.status()=='idle' and #calls==2 and calls[2]==original and equipped==original,'partial native equip did not roll back')
        elseif mode=='context_change' or mode=='owner_gone' then
            valid=false;api.update();assert(api.status()=='owner_lost' and next(releases)==nil,'living old unit lost package lease')
            gone=true;api.update();assert(api.status()=='idle' and #calls==1,'old owner teardown equipped another context')
        elseif mode=='verify_timeout' then
            assert(api.status()=='equipping');time=6;api.update();assert(api.status()=='idle' and equipped==original)
        else
            assert(api.status()=='active' and next(releases)==nil and #calls==1)
            api.restore('test_complete')
            if mode=='restore_error' then
                assert(api.status()=='restore_failed' and next(releases)==nil,'failed restoration unloaded active model')
                gone=true;api.update()
            else assert(api.status()=='idle' and equipped==original) end
        end
    end
    if mode=='process_pin' then
        assert(pinned and next(releases)==nil,'process lifetime shared resources unloaded after restoration')
        -- The game process has ended in this fixture; engine shutdown can now
        -- release resources after every animation consumer has gone.
        pinned:destroy()
    end
    for id in ipairs(loads) do assert(releases[id],'native package ref leaked after successful restore/owner deletion') end
    assert(original.gear_id=='original' and candidate.gear_id=='owned','transaction mutated an owned item')
end
print('testlab_loadout=pass native_package_loader async_both_item_leases partial_equip_rollback restoration_failure_hold context_loss no_backend_mutation')
-- Execute the real game's slot adapter, rather than only the transaction
-- engine. A ranged transaction must preserve BOTH profile identities and
-- restore the same slot that supplied its original item.
do
    local file=assert(io.open(root..'/mods/darktide_testlab/scripts/mods/darktide_testlab/darktide_testlab.lua','r'))
    local source=file:read('*all');file:close()
    local first=assert(source:find('temporary_weapon=mod:io_dofile(',1,true))
    local last=assert(source:find('\nlocal function start_manual_combat()',first,true))
    local unit,session={},{}
    local originals={slot_primary={gear_id='original_melee'},slot_secondary={gear_id='original_gun'}}
    local profile={archetype={breed='human',name='zealot'},loadout={slot_primary=originals.slot_primary,slot_secondary=originals.slot_secondary}}
    local weapon={_inventory_component={wielded_slot='slot_primary'},_weapons={}}
    local p={player_unit=unit,character_id=function() return 'character' end,profile=function() return profile end}
    local adapter,calls
    local scope=setmetatable({
        mod={io_dofile=function() return {new=function(options) adapter=options;return {} end} end},
        state={pinned_loaders={},clock=0},local_range=function() return true end,player=function() return p end,
        same_weapon_owner=function(context) return context.unit==unit and context.session==session end,
        cleanup=function() return true end,event=function() end,
        Managers={state={game_session=session},time={time=function() return 1 end}},
        Unit={alive=function() return true end},
        ScriptUnit={extension=function(_,name)
            if name=='weapon_system' then return weapon end
            assert(name=='visual_loadout_system')
            return {item_in_slot=function(_,slot) return originals[slot] end}
        end,has_extension=function() return weapon end},
        WeaponTemplate={weapon_template_from_item=function(item) return {actions=item.actions} end},
        VisualLoadout={equip_item_to_slot=function(u,item,slot)
            assert(u==unit);calls=calls+1;weapon._weapons[slot]={item=item}
        end},
    },{__index=_G})
    setfenv(assert(loadstring(source:sub(first,last-1))),scope)()
    for _,slot in ipairs({'slot_primary','slot_secondary'}) do
        calls=0;weapon._inventory_component.wielded_slot=slot
        local context=adapter.context()
        assert(context.slot==slot and context.original==originals[slot])
        local item={gear_id='owned_'..slot,name='native_item',slots={slot},actions={
            attack={kind=slot=='slot_primary' and 'sweep' or 'shoot_hit_scan'}}}
        assert(adapter.eligible(context,item))
        local foreign_slot={gear_id='other',slots={slot=='slot_primary' and 'slot_secondary' or 'slot_primary'},actions=item.actions}
        assert(not adapter.eligible(context,foreign_slot),'wrong-slot candidate accepted')
        adapter.equip(context,item);assert(adapter.equipped(context,item))
        adapter.equip(context,context.original);assert(adapter.equipped(context,context.original))
        assert(calls==2 and profile.loadout.slot_primary==originals.slot_primary and profile.loadout.slot_secondary==originals.slot_secondary)
        profile.loadout.slot_secondary={gear_id='unexpected_backend_change'}
        assert(not pcall(adapter.equip,context,item),'secondary profile mutation went undetected')
        profile.loadout.slot_secondary=originals.slot_secondary
    end
    weapon._inventory_component.wielded_slot='slot_grenade_ability'
    assert(not pcall(adapter.context),'non-weapon slot accepted')
end
print('testlab_loadout_adapter=pass actual_primary_secondary_slots both_profile_guards same_slot_restoration')
