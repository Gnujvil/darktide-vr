local Inventory=dofile(assert(arg[1]))
local current={unit={},session={},character='fixture'}
local callbacks,events={},{}
local fetches=0
local api=Inventory.new({context=function() return current end,
    same_context=function(context) return context==current end,
    fetch=function(context)
        assert(context==current);fetches=fetches+1
        local promise={}
        function promise:next(fn) self.ready=fn;return self end
        function promise:catch(fn) self.failed=fn;return self end
        callbacks[#callbacks+1]=promise;return promise
    end,
    describe=function(id,item) assert(item.untouched);return id..' '..item.name end,
    emit=function(id,kind,detail) events[#events+1]={id,kind,detail} end})
local items={b={name='chain',untouched=true},a={name='sword',untouched=true}}
api.fetch('one');callbacks[1].ready(items)
assert(fetches==1 and #events==3 and events[1][3]=='a sword' and events[2][3]=='b chain')
assert(events[3][2]=='inventory_ready' and items.a.untouched and items.b.untouched)
api.fetch('old');api.fetch('new');callbacks[2].ready(items)
assert(#events==3,'superseded asynchronous response published')
callbacks[3].ready(items);assert(#events==6 and events[4][1]=='new')
api.fetch('changed');current={};callbacks[4].ready(items);callbacks[4].failed('late error')
assert(#events==6,'other character/session inherited response')
api.fetch('cancel');api.cancel();callbacks[5].ready(items);assert(#events==6)
api.fetch('error');callbacks[6].failed('native inventory failure')
assert(events[7][2]=='inventory_error' and events[7][3]=='native inventory failure')
api.fetch('bad');callbacks[7].ready(false);assert(events[8][2]=='inventory_error')
local oversized={};for i=1,513 do oversized[tostring(i)]={name='entry',untouched=true} end
api.fetch('large');callbacks[8].ready(oversized)
assert(#events==9 and events[9][2]=='inventory_error','oversized inventory partially published')
print('testlab_inventory=pass read_only owned_rows sorted bounded async_supersession context_loss cancel failure')
