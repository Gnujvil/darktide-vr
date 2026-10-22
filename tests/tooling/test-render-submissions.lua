local f=assert(io.open(arg[1],'r')); local text=f:read('*all'); f:close()
local begin=assert(text:find('    if world == active_world and active and ui_native_capture_active and',1,true))
local last=assert(text:find('    if world == ui_stereo_world and ui_stereo_spawner and',begin,true))
local branch=text:sub(begin,last-1)
local function run(single,reverse,timing,direct)
    local calls,arms,captures,waits,logs=0,{},0,0,0
    -- The second-eye world update guard: armed only around the second render.
    local guarded,armed_calls=false,{}
    local first,second={},{}
    local world={}
    local env=setmetatable({active_world=world,active=true,ui_native_capture_active=true,
        ui_native_sync_requested=not direct,ui_native_sync_initialized=true,
        ui_direct_swapchain_capture_requested=direct,
        primary_viewport_name='left',right_viewport_name='right',
        presentation={single_submission_probe_requested=single,
            reverse_eye_order_probe_requested=reverse,
            update_performance_pass_trace=function()end,
            arm_second_eye_world_update=function(armed) guarded=armed end,
            trace_body_capture_boundary=function()end},
        mod={info=function() logs=logs+1 end},
        ScriptWorld={viewport=function(_,name)return name=='left' and first or second end,
            activate_viewport=function()end,deactivate_viewport=function()end},
        ui_native_capture={dtvr_boundary_eye_capture_count=function()return 0 end,
            dtvr_capture_armed_swapchain_eye=function()captures=captures+1;return 0 end},
        arm_eye_capture=function(eye)arms[#arms+1]=eye;return 0 end,
        report_native_capture_result=function()end,
        wait_for_eye_capture=function()waits=waits+1 end,
        performance_tick=function()return timing and 1 or nil end,
        record_render_timings=function()end,report_native_observer=function()end,
        render_eye_from_prepared_frame=function()return false end,
    },{__index=_G})
    local chunk=assert(loadstring('return function(world,func,...)\n'..branch..'\nend'))
    setfenv(chunk,env); local hook=chunk()
    for _=1,2 do assert(hook(world,function()calls=calls+1;armed_calls[calls]=guarded;return 'stock_result' end)=='stock_result') end
    assert(not guarded,'second-eye guard left armed after the frame')
    for i,armed in ipairs(armed_calls) do
        assert(armed==(not single and i%2==0),'second-eye guard armed around the wrong render')
    end
    assert(calls==(single and 2 or 4))
    assert(#arms==calls and captures==(direct and calls or 0) and waits==(direct and 0 or calls))
    for i,eye in ipairs(arms) do
        assert(eye==(single and (reverse and 1 or 0) or ((i%2==1)==not reverse and 0 or 1)))
    end
    assert(logs==(single and 1 or 0),'diagnostic logs once, no per-frame spam')
end
for _,s in ipairs({false,true}) do for _,r in ipairs({false,true}) do
    for _,t in ipairs({false,true}) do for _,d in ipairs({false,true}) do run(s,r,t,d) end end
end end
print('render_submissions=pass production_branch cases=16 stock_return capture_arm wait timing reverse_eye')
