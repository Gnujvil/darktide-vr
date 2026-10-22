local f=assert(io.open(arg[1],'r'));local source=f:read('*a');f:close()
local body=assert(source:match('elseif verb=="combat" then(.-)elseif verb=="status" then'))
local state,private,toggles,events={},true,0,{}
local env=setmetatable({state=state,local_range=function() return private end,
    isolation={active=function() return state.isolated==true end},
    threat={status=function() return state.threat or 'idle' end},
    mod={spawn_combat_enemy=function() state.spawn_requests=(state.spawn_requests or 0)+1;return true end,toggle_combat=function()
        toggles=toggles+1
        state.manual=not state.manual and {} or nil
        state.manual_pending=nil;state.isolated=false;state.threat='idle'
    end},event=function(kind,value) events[#events+1]={kind,value} end},{__index=_G})
local run=assert(loadstring('return function(args) '..body..' end'))
setfenv(run,env);run=run()
run('off');assert(toggles==0)
run('on');assert(toggles==1 and state.manual)
run('on');assert(toggles==1,'Repeated on toggled combat off')
run('off');assert(toggles==2 and not state.manual)
run('off');assert(toggles==2,'Repeated off toggled combat on')
state.manual_pending=true;run('on');assert(toggles==2)
run('off');assert(toggles==3 and not state.manual_pending)
state.manual=nil;state.isolated=true;run('off');assert(toggles==4)
state.manual=nil;state.threat='restore_pending';run('off');assert(toggles==5)
private=false;assert(not pcall(run,'on'));assert(toggles==5,'Public combat request executed')
private=true;assert(not pcall(run,'toggle'));assert(toggles==5)
run('spawn');assert(state.spawn_requests==1 and toggles==5)
assert(events[1][1]=='combat_request')
print('testlab_combat_command=pass production_branch idempotence pending restoration public_refusal arguments')
