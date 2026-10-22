-- Temporary session-only equip transaction. The adapter supplies the native
-- profile package loader and visual-loadout utility; no backend equip API.
local Loadout={}
function Loadout.new(options)
    local transaction
    local api={}
    local function emit(kind,reason)
        options.emit(kind,{reason=reason,phase=transaction and transaction.phase or 'idle'})
    end
    local function retire(reason)
        local old=transaction
        if old then
            if options.retire_loader then options.retire_loader(old.loader,old.context) else old.loader:destroy() end
            transaction=nil;emit('weapon_restored',reason)
        end
    end
    function api.status() return transaction and transaction.phase or 'idle' end
    function api.begin(item)
        assert(not transaction,'temporary_weapon_busy')
        local context=assert(options.context(),'local_weapon_context_required')
        assert(options.eligible(context,item),'ineligible_owned_weapon')
        assert(context.original and context.original.gear_id,'original_item_identity_required')
        local loader=options.loader(context)
        transaction={context=context,item=item,loader=loader,phase='loading',start=options.clock()}
        local ok,err=pcall(function()
            -- Separate slots retain BOTH package leases through the entire swap.
            loader:load_slot_item('original',context.original)
            loader:load_slot_item('candidate',item)
        end)
        if not ok then retire('package_error');error(err,0) end
        emit('weapon_loading',item.gear_id)
    end
    function api.restore(reason)
        local tx=transaction
        if not tx then return true end
        if not tx.changed then retire(reason);return true end
        if not options.current(tx.context) then
            tx.phase='owner_lost';emit('weapon_restore_pending','original_owner_unavailable');return false
        end
        tx.phase='restoring';tx.start=options.clock()
        local ok,err=pcall(options.equip,tx.context,tx.context.original)
        if not ok then tx.phase='restore_failed';emit('weapon_restore_error',tostring(err));return false end
        if options.equipped(tx.context,tx.context.original) then retire(reason);return true end
        return false
    end
    function api.update()
        local tx=transaction
        if not tx then return end
        if options.gone(tx.context) then retire('owner_destroyed');return end
        if not options.current(tx.context) then
            if not tx.changed then retire('context_changed_before_equip');return end
            if tx.phase~='owner_lost' then tx.phase='owner_lost';emit('weapon_restore_pending','context_changed') end
            return -- Never unload models still referenced by a living old unit.
        end
        if tx.phase=='owner_lost' then api.restore('context_recovered');return end
        if tx.phase=='loading' then
            if options.clock()-tx.start>30 then api.restore('package_timeout');return end
            if not tx.loader:is_slot_loaded('original',tx.context.original.name) or
                not tx.loader:is_slot_loaded('candidate',tx.item.name) then return end
            tx.phase='equipping';tx.changed=true;tx.start=options.clock()
            local ok,err=pcall(options.equip,tx.context,tx.item)
            if not ok then emit('weapon_equip_error',tostring(err));api.restore('equip_error');return end
        end
        if tx.phase=='equipping' then
            if options.equipped(tx.context,tx.item) then tx.phase='active';emit('weapon_ready',tx.item.gear_id)
            elseif options.clock()-tx.start>5 then api.restore('equip_timeout') end
        elseif tx.phase=='restoring' then
            if options.equipped(tx.context,tx.context.original) then retire('verified')
            elseif options.clock()-tx.start>5 then tx.phase='restore_failed';emit('weapon_restore_error','verify_timeout') end
        end
    end
    return api
end
return Loadout
