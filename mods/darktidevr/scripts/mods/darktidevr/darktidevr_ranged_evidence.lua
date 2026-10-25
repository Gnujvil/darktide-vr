-- Bounded observation after stock dispatch. No input, action, pose or hit writes.
--
-- The detail is capped per weapon route because four shots show the geometry
-- and four hundred show it four hundred times. The COUNT is not capped, and
-- that distinction was bought the hard way: on 18 September the gun stopped
-- producing bullets mid-session while the trigger, the sound and the animation
-- all still worked, and the log could not answer whether a shot had been
-- dispatched at all, because the last line it wrote was the fourth, four
-- minutes before the fault. "No line" meant "capped", not "no shot", so the
-- one question that mattered had no answer in a 13,000 line log.
--
-- So past the cap a compact line still goes out, throttled by time rather than
-- by count: enough that a burst of fire always leaves a mark, few enough that
-- holding down an autogun does not fill the file.
local Evidence={}
local DETAIL_SHOTS=4
local SUMMARY_SECONDS=5
-- The count throttle used when there is no usable clock. Chosen so a fast
-- weapon still writes a line every couple of seconds rather than per shot.
local SUMMARY_SHOTS=20
local function finite(n) return type(n)=='number' and n==n and math.abs(n)<math.huge end
function Evidence.ray_to_point(origin,direction,point)
    local delta=point-origin
    local length2,forward2=Vector3.length_squared(delta),Vector3.length_squared(direction)
    if not finite(length2) or not finite(forward2) or length2<1e-8 or forward2<1e-8 then return end
    local along=Vector3.dot(delta,direction)/math.sqrt(forward2)
    if not finite(along) then return end
    local cosine=math.max(-1,math.min(1,along/math.sqrt(length2)))
    return math.deg(math.acos(cosine)),math.sqrt(math.max(0,length2-along*along)),along
end
-- Where the crosshair point sits seen from the shot: degrees above and to the
-- right of its direction (world z up), so a crosshair drawn low reads
-- negative. nil when the point is not ahead of the shot or the shot is vertical.
function Evidence.offset_degrees(origin,direction,point)
    local dx,dy,dz=Vector3.x(direction),Vector3.y(direction),Vector3.z(direction)
    local n=math.sqrt(dx*dx+dy*dy+dz*dz)
    if not finite(n) or n<1e-6 then return end
    dx,dy,dz=dx/n,dy/n,dz/n
    local rx,ry=dy,-dx
    local rn=math.sqrt(rx*rx+ry*ry)
    if rn<1e-6 then return end
    rx,ry=rx/rn,ry/rn
    local ux,uy,uz=ry*dz,-rx*dz,rx*dy-ry*dx
    local tx,ty,tz=Vector3.x(point)-Vector3.x(origin),Vector3.y(point)-Vector3.y(origin),Vector3.z(point)-Vector3.z(origin)
    local along=tx*dx+ty*dy+tz*dz
    if not finite(along) or along<=1e-6 then return end
    return math.deg(math.atan2(tx*ux+ty*uy+tz*uz,along)),math.deg(math.atan2(tx*rx+ty*ry,along))
end
local function vector_text(v)
    if not v then return 'unavailable' end
    local x,y,z=Vector3.x(v),Vector3.y(v),Vector3.z(v)
    if not finite(x) or not finite(y) or not finite(z) then return 'invalid' end
    return string.format('%.4f,%.4f,%.4f',x,y,z)
end
function Evidence.install(mod,presentation)
    local instance={rows={},failures=0,total=0}
    instance.hits=mod:io_dofile('darktidevr/scripts/mods/darktidevr/darktidevr_hit_evidence').install(mod,presentation)
    local owner,session
    local alignment
    function mod.request_crosshair_check(unit,count)
        assert(presentation.online_rules.simulation_aim_active(unit),'local_aim_unavailable')
        assert(type(count)=='number' and count==math.floor(count) and count>=1 and count<=60,'crosshair_count_1_to_60')
        local t=Managers.time:time('main')
        assert(finite(t),'crosshair_clock_unavailable')
        alignment={unit=unit,session=Managers.state.game_session,remaining=count,index=0,
            started=t,expires=t+count*.1+5}
    end
    local function capture_alignment(unit,template,muzzle_unit,muzzle_node,grip,gear_id)
        local request=alignment
        if not request then return end
        if request.unit~=unit then return end
        if request.session~=Managers.state.game_session or
            not presentation.online_rules.simulation_aim_active(unit) then alignment=nil;return end
        if request.weapon and (request.weapon~=template.name or request.gear_id~=gear_id) then
            alignment=nil;return
        end
        local t=Managers.time:time('main')
        if not finite(t) or t<request.started or t>request.expires then
            alignment=nil;mod:info('DARKTIDEVR_CROSSHAIR_CHECK unavailable=pose_sample_deadline');return
        end
        if request.next_t and t<request.next_t then return end
        local aim=presentation.controller_aim
        local point=aim and aim.cached_reticle_target()
        if not point then return end
        request.weapon,request.gear_id=template.name,gear_id
        point=point:unbox()
        local muzzle=Unit.world_position(muzzle_unit,muzzle_node)
        local rotation=Unit.world_rotation(muzzle_unit,muzzle_node)
        local bore_angle,bore_miss=Evidence.ray_to_point(muzzle,Quaternion.forward(rotation),point)
        local sights=presentation.gun_sights
        local offset=sights and sights.sight_offset(template.name)
        local sight_angle,sight_miss,sight_along
        if offset then
            local origin=grip+Quaternion.rotate(rotation,Vector3(offset.x,0,offset.z))
            local axis=offset.axis or {0,1,0}
            sight_angle,sight_miss,sight_along=Evidence.ray_to_point(origin,
                Quaternion.rotate(rotation,Vector3(axis[1],axis[2],axis[3])),point)
        end
        request.index=request.index+1;request.remaining=request.remaining-1;request.next_t=t+.1
        mod:info('DARKTIDEVR_CROSSHAIR_CHECK weapon=%s gear_id=%s sample=%d main_t=%.6f reticle_sequence=%s sight_calibrated=%s sight_angle_deg=%s sight_miss_m=%s sight_along_m=%s bore_angle_deg=%s bore_miss_m=%s grip=%s muzzle=%s target=%s source=posed_weapon',
            tostring(template.name),tostring(gear_id),request.index,t,tostring(aim.reticle_point_sequence),
            tostring(offset~=nil),tostring(sight_angle or 'unavailable'),tostring(sight_miss or 'unavailable'),
            tostring(sight_along or 'unavailable'),tostring(bore_angle or 'unavailable'),tostring(bore_miss or 'unavailable'),
            vector_text(grip),vector_text(muzzle),vector_text(point))
        if request.remaining==0 then alignment=nil end
    end
    function instance.capture_alignment(...)
        if not alignment then return end
        local ok,message=pcall(capture_alignment,...)
        if not ok then
            alignment=nil
            mod:info('DARKTIDEVR_CROSSHAIR_CHECK unavailable=%s',tostring(message):sub(1,160))
        end
    end
    local function observe(action,position,rotation,power,charge,t)
        if not presentation.online_rules.simulation_aim_active(action._player_unit) or
                (action._unit_data_extension and action._unit_data_extension.is_resimulating) then return end
        -- The same dispatch drives the immersive shot vibration (one hook per method).
        if presentation.haptics and presentation.haptics.shot then pcall(presentation.haptics.shot,action) end
        local current_session=Managers.state.game_session
        if owner~=action._player_unit or session~=current_session then
            owner,session,instance.rows=action._player_unit,current_session,{}
        end
        local template=action._weapon_template
        local weapon=tostring(template and template.name or 'unknown')
        local kind=tostring(action._action_settings and action._action_settings.kind or action.__class_name or 'unknown')
        local key=weapon..'/'..kind
        local row=instance.rows[key]
        if not row then row={calls=0} instance.rows[key]=row end
        row.calls=row.calls+1
        instance.total=instance.total+1
        if row.calls>DETAIL_SHOTS then
            -- Past the detail cap. A count and a time, so a later reader can
            -- ask "did anything fire here" and get an answer.
            -- An unusable time falls back to counting rather than logging.
            -- Written the other way round -- "unknown time, log anyway" -- it
            -- also stored nil, so a single bad `t` disarmed the throttle
            -- permanently and a fast weapon then wrote a line per shot for the
            -- rest of the session (review, 18 September).
            local now=type(t)=='number' and t==t and t or nil
            local due
            if now then due=row.summary_t==nil or now>=row.summary_t+SUMMARY_SECONDS
            else due=row.calls-(row.summary_calls or DETAIL_SHOTS)>=SUMMARY_SHOTS end
            if due then
                row.summary_t=now or row.summary_t
                local since=row.calls-(row.summary_calls or DETAIL_SHOTS)
                row.summary_calls=row.calls
                mod:info('DARKTIDEVR_RANGED_EVIDENCE weapon=%s kind=%s dispatches=%d since_last=%d time=%s',
                    weapon,kind,row.calls,since,tostring(t))
            end
            return
        end
        local direction=rotation and Quaternion.forward(rotation)
        local aim=presentation.controller_aim
        local point=aim and aim.cached_reticle_target()
        local angle,above,right='unavailable','unavailable','unavailable'
        local target=point and point:unbox()
        if target and position and direction then
            local toward=target-position
            if Vector3.length_squared(toward)>1e-8 then
                local dot=Vector3.dot(Vector3.normalize(toward),Vector3.normalize(direction))
                if finite(dot) then angle=string.format('%.3f',math.deg(math.acos(math.max(-1,math.min(1,dot))))) end
            end
            local up_degrees,right_degrees=Evidence.offset_degrees(position,direction,target)
            if up_degrees then above,right=string.format('%.3f',up_degrees),string.format('%.3f',right_degrees) end
        end
        local result=action._shot_result
        local hit=result and result.data_valid and tostring(result.hit_minion==true) or 'unknown'
        local action_name=action._weapon_action_component and action._weapon_action_component.current_action_name
        local muzzle,muzzle_rotation
        if aim and aim.third_person_muzzle then
            local fired=action._action_component and action._action_component.num_shots_fired
            -- Stock preparation has already advanced this count; observe the
            -- barrel used by this shot, not the next alternating muzzle.
            muzzle,muzzle_rotation=aim.third_person_muzzle(action,finite(fired) and math.max(0,fired-1) or nil)
        end
        local muzzle_direction=muzzle_rotation and Quaternion.forward(muzzle_rotation)
        mod:info('DARKTIDEVR_RANGED_EVIDENCE weapon=%s kind=%s action=%s dispatch=%d authority=%s time=%s charge=%s origin=%s direction=%s shot_vs_reticle_deg=%s reticle_above_shot_deg=%s reticle_right_of_shot_deg=%s reticle=%s hit_minion=%s muzzle=%s muzzle_node_forward=%s',
            weapon,kind,tostring(action_name or 'unknown'),row.calls,
            action._is_server and 'server' or 'client',tostring(t),tostring(charge),
            vector_text(position),vector_text(direction),angle,above,right,vector_text(target),hit,
            vector_text(muzzle),vector_text(muzzle_direction))
    end
    function instance.observe(...)
        local ok,message=pcall(observe,...)
        if not ok then
            instance.failures=instance.failures+1
            if instance.failures==1 then
                -- Diagnostic failure must not create repeating audible mod errors.
                pcall(mod.info,mod,'DARKTIDEVR_RANGED_EVIDENCE unavailable=%s',tostring(message):sub(1,160))
            end
        end
    end
    for _,name in ipairs({'action_shoot_hit_scan','action_shoot_pellets','action_shoot_projectile',
            'action_flamer_gas','action_flamer_gas_burst'}) do
        mod:hook_safe(require('scripts/extension_systems/weapon/actions/'..name),'_shoot',instance.observe)
    end
    mod:command('dtvr_ranged_evidence','Report observed stock ranged dispatches',function()
        local keys={}
        for key in pairs(instance.rows) do keys[#keys+1]=key end
        table.sort(keys)
        -- instance.total counts the session; instance.rows is wiped on an
        -- owner or game-session change, so say which is which rather than
        -- print a total that does not add up to the lines under it.
        mod:echo('Ranged evidence: %d weapon routes, %d dispatches since the last respawn, %d this session, %d diagnostic failures',
            #keys,(function() local n=0 for _,row in pairs(instance.rows) do n=n+row.calls end return n end)(),
            instance.total,instance.failures)
        for _,key in ipairs(keys) do mod:echo('%s: %d stock dispatches',key,instance.rows[key].calls) end
    end)
    return instance
end
return Evidence
