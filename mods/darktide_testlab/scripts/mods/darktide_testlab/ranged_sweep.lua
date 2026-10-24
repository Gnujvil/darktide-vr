-- Ranged weapon sweep: equip each template with the temporary loadout, wait
-- until it is drawn and idle, sample its hand/muzzle frames, restore, next.
-- Engine access comes through deps; this file only sequences and reports.
--   deps.weapon        temporary loadout api: begin(item), status(), restore(reason)
--   deps.item(name)    -> item | nil,reason (a session-only any-class item)
--   deps.capacity()    -> temporary equips left in this process
--   deps.idle()        -> true when the wielded weapon runs no action
--   deps.measure()     -> one engine frame for RangedPose.relatives | nil,reason
--   deps.template()    -> wielded weapon template name
--   deps.vr_data(name) -> text describing the VR mod's own per-weapon data
--   deps.clock(), deps.emit(kind,detail)
local Sweep={}
Sweep.SETTLE=1.2
Sweep.SAMPLES=15
Sweep.TEMPLATE_TIMEOUT=25
function Sweep.new(Pose,deps)
    local api={}
    local job
    function api.status() return job and job.phase or "idle" end
    local function finish(reason)
        local current=job
        if not current then return end
        local baseline,flags=Pose.flag(current.rows,{baseline=current.baseline})
        for _,row in ipairs(current.rows) do deps.emit("ranged_pose",Pose.row_text(row)) end
        local names={}
        for metric,value in pairs(baseline) do names[#names+1]=string.format("%s=%.1f(n=%d)",metric,value.roll,value.count) end
        table.sort(names)
        deps.emit("ranged_roll_baseline",#names>0 and table.concat(names," ") or "unavailable reason=no_baseline_template_measured")
        for _,flag in ipairs(flags) do
            deps.emit("ranged_roll_flag",string.format("template=%s metric=%s roll=%.1f baseline=%.1f delta=%.1f threshold=%d",
                flag.template,flag.metric,flag.roll,flag.baseline,flag.delta,Pose.THRESHOLD_DEGREES))
        end
        local remaining={}
        for i=current.index,#current.list do remaining[#remaining+1]=current.list[i] end
        deps.emit("ranged_sweep_done",string.format("reason=%s measured=%d skipped=%d flagged=%d remaining=%s",
            reason,#current.rows,current.skipped,#flags,#remaining>0 and table.concat(remaining,",") or "none"))
        job=nil
    end
    local function skip(name,reason)
        job.skipped=job.skipped+1
        deps.emit("ranged_sweep_skip","template="..tostring(name).." reason="..tostring(reason))
    end
    local function next_template()
        while job.index<=#job.list do
            local name=job.list[job.index]
            if deps.capacity()<=0 then return finish("process_equip_limit_restart_required") end
            local item,why=deps.item(name)
            if not item then skip(name,why or "unknown_template");job.index=job.index+1
            else
                local ok,err=pcall(deps.weapon.begin,item)
                if ok then
                    job.current={name=name,start=deps.clock(),frames={}};job.phase="loading"
                    deps.emit("ranged_sweep_equip","template="..name.." "..deps.vr_data(name))
                    return
                end
                skip(name,err);job.index=job.index+1
            end
        end
        finish("complete")
    end
    function api.begin(list,options)
        assert(not job,"ranged_sweep_busy")
        assert(type(list)=="table" and #list>=1,"ranged_sweep_needs_templates")
        assert(deps.weapon.status()=="idle","temporary_weapon_busy")
        job={list=list,index=1,rows={},skipped=0,phase="starting",baseline=options and options.baseline}
        deps.emit("ranged_sweep_started",string.format("templates=%d capacity=%d list=%s",#list,deps.capacity(),table.concat(list,",")))
        next_template()
    end
    local function advance()
        job.index=job.index+1;job.current=nil;job.phase="starting"
        next_template()
    end
    local function restore(reason)
        job.phase="restoring";job.restore_reason=reason
        deps.weapon.restore("ranged_sweep")
    end
    function api.update()
        if not job then return end
        local current=job.current
        if job.phase=="restoring" then
            if deps.weapon.status()=="idle" then advance() end
            return
        end
        if not current then return end
        local now=deps.clock()
        if now-current.start>Sweep.TEMPLATE_TIMEOUT then skip(current.name,"timeout_"..job.phase);return restore("timeout") end
        local status=deps.weapon.status()
        if job.phase=="loading" then
            if status=="active" then job.phase="settling";current.ready=now
            elseif status=="idle" then skip(current.name,"equip_failed");advance() end
            return
        end
        if status~="active" then skip(current.name,"weapon_lost_"..status);return restore("weapon_lost") end
        if job.phase=="settling" then
            if deps.template()~=current.name then skip(current.name,"wielded_template_mismatch");return restore("mismatch") end
            if deps.idle() and now-current.ready>=Sweep.SETTLE then job.phase="sampling" end
            return
        end
        if job.phase=="sampling" then
            if not deps.idle() then return end
            local frame,why=deps.measure()
            if frame then current.frames[#current.frames+1]=frame
            else current.failures=(current.failures or 0)+1;current.why=why end
            if #current.frames>=Sweep.SAMPLES then
                job.rows[#job.rows+1]=Pose.combine(current.name,current.frames)
                return restore("measured")
            end
            if (current.failures or 0)>Sweep.SAMPLES then skip(current.name,"measure_"..tostring(current.why));return restore("measure_failed") end
        end
    end
    function api.cancel(reason)
        if not job then return true end
        if job.current and deps.weapon.status()~="idle" then deps.weapon.restore("ranged_sweep_cancel") end
        finish(reason or "cancelled")
        return true
    end
    return api
end
return Sweep
