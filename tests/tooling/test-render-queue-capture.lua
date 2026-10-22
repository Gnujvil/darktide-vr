local Queue=dofile(assert(arg[1]))
local function pack(...) return {n=select('#',...),...} end
local world,left,right,other={},{},{},{}
local events,resets,native_calls={},0,0
local fail_before,fail_after
local api=Queue.new({
    left_first=true,
    before_eye=function(eye)
        events[#events+1]='before'..eye
        if fail_before then error('before failure') end
        return eye+10
    end,
    after_eye=function(eye,target)
        assert(target==eye+10);events[#events+1]='after'..eye
        if fail_after then error('after failure') end
    end,
    reset=function() resets=resets+1 end,
})
local function native(w,c,v,s,...)
    native_calls=native_calls+1
    events[#events+1]=v==left and 'native0' or v==right and 'native1' or 'foreign'
    return nil,'native_result',nil
end
local function submit(v)
    local result=pack(api.native(native,world,'camera',v,'shading'))
    assert(result.n==3 and result[1]==nil and result[2]=='native_result' and result[3]==nil)
end
local function stock(w,value)
    assert(w==world and value=='argument')
    submit(left);submit(right)
    return nil,'stock_result',nil
end
local result=pack(api.run(world,left,right,stock,'argument'))
assert(result.n==3 and result[2]=='stock_result' and result[3]==nil)
assert(table.concat(events,',')=='before0,native0,after0,before1,native1,after1')
submit(other);assert(events[#events]=='foreign' and resets==0)
for _,failure in ipairs({'before','after','native','missing','duplicate','nested'}) do
    fail_before,fail_after=failure=='before',failure=='after'
    local before=native_calls
    local ok=pcall(api.run,world,left,right,function()
        if failure=='native' then
            api.native(function() error('native failure') end,world,'camera',left,'shading')
        elseif failure=='nested' then api.run(world,left,right,stock,'argument')
        else submit(left);if failure=='duplicate' then submit(left) end end
    end)
    assert(not ok,'failure escaped rejection: '..failure)
    if failure=='duplicate' then assert(native_calls==before+1,'duplicate native work was submitted') end
    fail_before,fail_after=false,false
    local count=#events;submit(left)
    assert(#events==count+1 and events[#events]=='native0','scope leaked after '..failure)
    assert(pack(api.run(world,left,right,stock,'argument')).n==3)
end
assert(resets==6)
local ok=pcall(api.run,world,left,right,function()submit(right);submit(left)end)
assert(not ok and resets==7,'marker replay order must be unambiguous')
api.run(world,left,right,function()
    local count=#events
    local result=pack(api.native(function(...)return ... end,other,'camera',left,'shading',nil,'extra',nil))
    assert(result.n==7 and result[1]==other and result[3]==left and result[6]=='extra')
    assert(#events==count,'foreign world inherited capture scope')
    submit(left);submit(right)
end)

-- Run the pinned upstream implementation through the production hook/branch.
-- This proves the Lua contract, not current-engine native ABI or crash safety.
local function read(path)
    local f=assert(io.open(path,'rb'));local s=f:read('*all');f:close()
    return (s:gsub('^\239\187\191',''))
end
local text=read(assert(arg[2]))
local install_start=assert(text:find('if presentation.stock_queue_capture_requested then',1,true))
local install_end=assert(text:find('-- Level stories can animate',install_start,true))
local branch_start=assert(text:find('    if world == active_world and active and ui_native_capture_active and',1,true))
local branch_end=assert(text:find('    if world == ui_stereo_world and ui_stereo_spawner and',branch_start,true))
local queue={left,right}
local arms,waits,activations,stock_calls,draws,lods,blends,applies=0,0,0,0,0,0,0,0
local marker_hides,marker_replays=0,0
local env=setmetatable({active_world=world,active=true,ui_native_capture_active=true,
    Managers={},
    stereo_world_markers_requested=true,
    enqueue_world_markers_for_camera=function(camera)
        assert(camera==right);marker_replays=marker_replays+1
    end,
    ui_native_sync_requested=true,ui_native_sync_initialized=true,
    primary_viewport_name='left',right_viewport_name='right',
    presentation={stock_queue_capture_requested=true,update_performance_pass_trace=function()end,
        marker_gui={hide=function()marker_hides=marker_hides+1 end},
        trace_body_capture_boundary=function()end},
    World={get_data=function(_,key)
        if key=='render_queue' then return queue end
        if key=='shadow_baked' then return true end
    end,update_lod_levels=function() lods=lods+1 end},
    Viewport={get_data=function(_,key) if key=='shading_environment' then return 'shading' end end,
        has_data=function()return false end},
    ShadingEnvironment={blend=function()blends=blends+1 end,apply=function()applies=applies+1 end},
    ui_native_capture={dtvr_boundary_eye_capture_count=function()return 0 end,
        dtvr_reset_eye_capture_tags=function()error('unexpected reset')end},
    arm_eye_capture=function()arms=arms+1;return 0 end,
    report_native_capture_result=function()end,wait_for_eye_capture=function()waits=waits+1 end,
    report_native_observer=function()end,
    Application={render_world=function()draws=draws+1 end},
    mod={info=function()end,io_dofile=function()return Queue end},
},{__index=_G})
env.require=function(name)
    if name:match('script_camera$') then return {} end
    if name:match('script_viewport$') then return {camera=function(v)return v end} end
    error(name)
end
env.mod.hook=function(_,target,name,hook)
    local original=target[name]
    target[name]=function(...)return hook(original,...)end
end
local chunk=assert(loadstring(read(assert(arg[3]))));setfenv(chunk,env)
env.ScriptWorld=chunk()
env.ScriptWorld.viewport=function(_,name)return name=='left' and left or right end
env.ScriptWorld.activate_viewport=function()activations=activations+1 end
env.ScriptWorld.deactivate_viewport=function()error('inter-eye viewport mutation')end
chunk=assert(loadstring(text:sub(install_start,install_end-1)));setfenv(chunk,env);chunk()
chunk=assert(loadstring('return function(world,func,...)\n'..text:sub(branch_start,branch_end-1)..'\nend'))
setfenv(chunk,env)
local hook=chunk()
hook(world,function(w) stock_calls=stock_calls+1;env.ScriptWorld.render(w) end)
assert(stock_calls==1 and draws==2 and arms==2 and waits==2)
assert(lods==2 and blends==2 and applies==2 and activations==2)
assert(marker_hides==1 and marker_replays==1,'existing right-eye marker replay lost')
print('render_queue_capture=pass stock_traversal native_eye_attribution returns error_cleanup production_branch')
