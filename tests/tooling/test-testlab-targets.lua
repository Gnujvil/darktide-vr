local Targets=dofile(assert(arg[1]))
local context={unit={},session={}}
local made,destroyed,events={},{},{}
local fail_spawn,fail_destroy
local api=Targets.new({alive=function(unit) return not unit.removed end,health=function(unit) return unit and unit.health or -1 end,
    spawn=function(spec)
        if spec.id==fail_spawn then error('native spawn failure') end
        local unit={health=100};made[#made+1]=unit;return unit
    end,
    destroy=function(unit)
        if unit==fail_destroy then error('native despawn failure') end
        assert(not destroyed[unit],'target destroyed twice');destroyed[unit]=true;unit.removed=true
    end,
    emit=function(kind,detail) events[#events+1]=kind..':'..detail end})
local specs={{id='group:1',generation=1,breed='first'},{id='group:2',generation=1,breed='second'},{id='group:3',generation=1,breed='third'}}
local entries=api.replace(specs,context)
local snapshots=api.capture(context)
assert(#entries==3 and #snapshots==3 and not api.owns({}) and api.find(snapshots,entries[2].unit)==snapshots[2])
entries[1].unit.health=70
snapshots[2].confirmed_native_kill=true;entries[2].unit.health=-1 -- native corpse without health extension
entries[3].unit.removed=true -- unexplained disappearance is not a kill
local first,second,third=api.outcome(snapshots[1],context),api.outcome(snapshots[2],context),api.outcome(snapshots[3],context)
assert(first.valid and first.delta==30 and second.valid and second.after==0 and second.source=='native_kill')
assert(not third.valid and third.after==-1 and third.delta==-1,'missing target fabricated a kill')
assert(not api.outcome(snapshots[2],{unit=context.unit,session={}}).valid,'kill leaked into a different session')
fail_destroy=entries[1].unit
local cleared,why=api.clear(context)
assert(not cleared and why=='owned_target_cleanup_pending' and #api.entries()==1)
local count=#made
assert(not pcall(api.replace,specs,context) and #made==count,'cleanup failure allowed another group')
fail_destroy=nil;assert(api.clear(context) and #api.entries()==0)
fail_spawn='group:3'
assert(not pcall(api.replace,specs,context) and #api.entries()==0,'partial spawn retained orphan units')
assert(made[#made].removed and made[#made-1].removed,'partial group not rolled back')
fail_spawn=nil;entries=api.replace(specs,context)
assert(api.clear({unit={},session=context.session}) and entries[1].unit.removed,'same-world player replacement orphaned owned units')
entries=api.replace(specs,context)
local old=entries[1].unit
assert(api.clear({unit=context.unit,session={}}) and not destroyed[old],'new level tried to delete old-world units')
assert(not pcall(api.replace,{},context))
assert(not pcall(api.replace,{specs[1],specs[1]},context),'duplicate target identity accepted')
do
    local unit,removed={},0
    local duplicate=Targets.new({alive=function() return true end,health=function() return 100 end,
        spawn=function() return unit end,destroy=function() removed=removed+1 end,emit=function() end})
    assert(not pcall(duplicate.replace,specs,context) and removed==1 and #duplicate.entries()==0,
        'duplicate native handle acquired twice or leaked')
end
print('testlab_targets=pass bounded_owned_group target_identity per_target_health confirmed_kill unknown_disappearance partial_spawn_rollback cleanup_retry session_retirement no_foreign_despawn')
