-- Anchored, immortal testlab targets. Engine-independent: the adapter
-- supplies reads and writes. Each update every adopted target that drifted
-- more than DISTANCE metres (pushed, staggered, walking) or turned more than
-- ANGLE degrees is put back at its spawn pose, and any health it lost is
-- given back, so a case keeps one target in reach and alive throughout.
--   deps.alive(unit), deps.position(unit) -> {x,y,z}, deps.rotation(unit) -> {x,y,z,w}
--   deps.teleport(unit,{x,y,z},{x,y,z,w})
--   deps.health(unit) -> current,max          deps.restore(unit)   (to full)
--   deps.prepare(unit) -> {unkillable=bool,no_stagger_buff=bool|string}
--   deps.guard(unit) -> bool                  (no_stagger keyword active)
--   deps.emit(kind,detail)
-- Damage is never prevented: the hit lands, the ledger records it, then the
-- health is restored (the target is also unkillable, so one hit larger than
-- its health still cannot kill it).
local Anchor={}
Anchor.DISTANCE=.05
Anchor.ANGLE=10
-- Updates to wait for the no_stagger keyword before reporting it absent.
Anchor.GUARD_CHECKS=30
local function finite(n) return type(n)=="number" and n==n and math.abs(n)<math.huge end
local function distance(a,b)
    return math.sqrt((a[1]-b[1])^2+(a[2]-b[2])^2+(a[3]-b[3])^2)
end
local function angle(a,b)
    if type(a)~="table" or type(b)~="table" or #a<4 or #b<4 then return 0 end
    local d=math.abs(a[1]*b[1]+a[2]*b[2]+a[3]*b[3]+a[4]*b[4])
    local na=math.sqrt(a[1]^2+a[2]^2+a[3]^2+a[4]^2)*math.sqrt(b[1]^2+b[2]^2+b[3]^2+b[4]^2)
    if na<1e-9 then return 0 end
    return math.deg(2*math.acos(math.min(1,d/na)))
end
function Anchor.text(t)
    return string.format("target=%s teleports=%d max_offset=%.3f max_angle=%.1f health_restores=%d health_restored=%.3f unkillable=%s no_stagger=%s%s%s",
        t.id,t.teleports,t.max_offset,t.max_angle,t.restores,t.healed,tostring(t.unkillable),tostring(t.no_stagger),
        t.teleport_error and " teleport_error="..t.teleport_error:gsub("%s+","_") or "",t.restore_error and " restore_error="..t.restore_error:gsub("%s+","_") or "")
end
function Anchor.new(deps)
    local records=setmetatable({},{__mode="k"})
    local order={}
    local api={text=Anchor.text}
    local function emit(kind,detail) pcall(deps.emit,kind,detail) end
    local function heal(record,unit)
        local ok,current,max=pcall(deps.health,unit)
        if not ok or not finite(current) or not finite(max) or current>=max-1e-6 then return false end
        local restored,err=pcall(deps.restore,unit)
        if not restored then
            if not record.restore_error then record.restore_error=tostring(err);emit("anchor_error","target="..record.id.." restore="..record.restore_error) end
            return false
        end
        record.restores=record.restores+1;record.healed=record.healed+(max-current)
        return true
    end
    function api.adopt(unit,id,position,rotation)
        assert(unit and type(position)=="table" and #position==3,"anchor_pose_required")
        local ok,result=pcall(deps.prepare,unit)
        local prepared=ok and type(result)=="table" and result or {error=tostring(result)}
        local record={unit=unit,id=tostring(id),position={position[1],position[2],position[3]},
            rotation=type(rotation)=="table" and #rotation==4 and {rotation[1],rotation[2],rotation[3],rotation[4]} or nil,
            teleports=0,restores=0,healed=0,max_offset=0,max_angle=0,prepared=prepared,guarded=nil}
        records[unit]=record;order[#order+1]=unit
        emit("anchor_adopted",string.format("target=%s position=%.3f,%.3f,%.3f unkillable=%s no_stagger_buff=%s%s",record.id,
            position[1],position[2],position[3],tostring(prepared.unkillable),tostring(prepared.no_stagger_buff),
            prepared.error and " error="..prepared.error or ""))
        return record
    end
    function api.owns(unit) return unit~=nil and records[unit]~=nil end
    function api.clear() records=setmetatable({},{__mode="k"});order={} end
    function api.count()
        local n=0
        for _,unit in ipairs(order) do if records[unit] then n=n+1 end end
        return n
    end
    -- Called right after a native attack on an owned target.
    function api.after_hit(unit)
        local record=unit and records[unit]
        if not record or not deps.alive(unit) then return false end
        return heal(record,unit)
    end
    function api.update()
        for _,unit in ipairs(order) do
            local record=records[unit]
            if record and deps.alive(unit) then
                if record.guarded==nil then
                    -- A buff's keyword becomes active on a later buff update.
                    record.guard_checks=(record.guard_checks or 0)+1
                    local ok,active=pcall(deps.guard,unit)
                    if ok and (active==true or record.guard_checks>=Anchor.GUARD_CHECKS) then
                        record.guarded=active==true
                        emit("anchor_ready",string.format("target=%s unkillable=%s no_stagger=%s checks=%d",record.id,
                            tostring(record.prepared.unkillable),tostring(record.guarded),record.guard_checks))
                    end
                end
                local ok,p=pcall(deps.position,unit)
                local okr,q=pcall(deps.rotation,unit)
                if ok and type(p)=="table" and finite(p[1]) then
                    local offset=distance(p,record.position)
                    local turn=okr and angle(q,record.rotation) or 0
                    if offset>record.max_offset then record.max_offset=offset end
                    if turn>record.max_angle then record.max_angle=turn end
                    if offset>Anchor.DISTANCE or (record.rotation and turn>Anchor.ANGLE) then
                        local moved,err=pcall(deps.teleport,unit,record.position,record.rotation or q)
                        if moved then record.teleports=record.teleports+1
                        elseif not record.teleport_error then
                            record.teleport_error=tostring(err)
                            emit("anchor_error","target="..record.id.." teleport="..record.teleport_error)
                        end
                    end
                end
                heal(record,unit)
            end
        end
    end
    -- Counts since the previous take (a run reports its own share).
    function api.take(unit)
        local record=unit and records[unit]
        if not record then return nil end
        local out={id=record.id,teleports=record.teleports-(record.taken_teleports or 0),
            restores=record.restores-(record.taken_restores or 0),healed=record.healed-(record.taken_healed or 0),
            max_offset=record.max_offset,max_angle=record.max_angle,unkillable=record.prepared.unkillable,
            no_stagger=record.guarded,teleport_error=record.teleport_error,restore_error=record.restore_error}
        record.taken_teleports=record.teleports;record.taken_restores=record.restores;record.taken_healed=record.healed
        record.max_offset=0;record.max_angle=0
        return out
    end
    return api
end
return Anchor
