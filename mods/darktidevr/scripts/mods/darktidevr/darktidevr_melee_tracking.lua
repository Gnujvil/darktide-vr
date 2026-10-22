-- Bridge tracking adapter. This transport label is not proof of physical
-- devices or worn acceptance. Explicit replay uses the separate synthetic source.
local Tracking={}
function Tracking.install(mod,presentation,tracking,game_mode,options)
    options=options or {}
    local prefix="darktidevr/scripts/mods/darktidevr/darktidevr_melee_"
    local function load(name) return mod:io_dofile(prefix..name) end
    local Runtime,Pose,Inertia,Strokes=load("runtime"),load("pose"),load("inertia"),load("strokes")
    local Weapons,Grip,GestureAim=load("weapons"),load("grip"),load("gesture_aim")
    local deps={Timing=load("timing"),Volume=load("volume"),Planner=load("sweep_plan"),Bridge=load("action_bridge"),Defense=load("defense"),Tether=load("tether"),
        Contact=load("contact")}
    local Probe,Contact=load("probe"),deps.Contact
    local defaults=require("scripts/settings/equipment/action_sweep_settings")
    local visual=load("visual").new()
    local api={}
    local state={strokes=Strokes.new(),owned=setmetatable({}, {__mode="k"}),blocked=setmetatable({}, {__mode="k"}),
        stock_sweeps=setmetatable({}, {__mode="k"})}
    local function log(kind,fields)
        local parts={}
        for key,value in pairs(fields or {}) do parts[#parts+1]=key.."="..tostring(value):gsub("[\r\n\t]"," ") end
        table.sort(parts)
        mod:info("DARKTIDEVR_PHYSICAL event=%s source=tracking transport=bridge hardware_verified=false %s",kind,table.concat(parts," "))
    end
    local function main_time() return Managers.time:time("main") end
    local function private()
        return game_mode()=="shooting_range" and Managers.state.game_session and Managers.state.game_session:is_server()
    end
    -- "physical" in the local Psykhanium: the tracked weapon itself sweeps.
    -- "stock" wherever the stock online-input rules hold (missions, local or
    -- remote): a swing presses the stock attack and the server sweeps.
    local function authority()
        if private() then return "physical" end
        local rules=presentation.online_rules
        if rules and rules.enabled() then return "stock" end
        return nil
    end
    state.latch=GestureAim.latch()
    local function first_person(unit)
        local extension=ScriptUnit.has_extension(unit,"first_person_system")
        local component=extension and extension._first_person_component
        return component and component.position
    end
    local function engine_frame(yaw,pitch,roll,v)
        local r=Quaternion.rotate(Quaternion.from_yaw_pitch_roll(yaw,pitch,roll),Vector3(v[1],v[2],v[3]))
        return {Vector3.x(r),Vector3.y(r),Vector3.z(r)}
    end
    -- A committed stock stroke: point the attack the server will run along it.
    local function commit_aim(unit,weapon,data)
        local head=first_person(unit)
        if not head then log("gesture_aim",{reason="head_unavailable"}); return end
        local settings=weapon.weapon_template.actions[data.action]
        local path,_,bounds
        if settings then path,_,bounds=deps.Timing.authored_path(weapon.weapon_template,settings) end
        local center=bounds and {(bounds[1]+bounds[2])/2,(bounds[3]+bounds[4])/2,(bounds[5]+bounds[6])/2}
        local yaw,pitch,roll,why=GestureAim.solve({Vector3.x(head),Vector3.y(head),Vector3.z(head)},data.points,path and path[#path],engine_frame,data.target,center)
        if not yaw then log("gesture_aim",{reason=pitch,action=data.action,points=#data.points}); return end
        state.latch.push({time=data.time,yaw=yaw,pitch=pitch,roll=roll})
        log("gesture_aim",{action=data.action,yaw=string.format("%.3f",yaw),pitch=string.format("%.3f",pitch),
            roll=roll and string.format("%.3f",roll) or "wrist",reason=why or "aligned",points=#data.points,time=data.time})
    end
    -- Online trigger option: "contact" (default) presses when the stroke's
    -- look-ahead reaches an enemy; "swing" presses on every stroke.
    local function trigger_mode()
        return mod.get and mod:get("vr_online_melee_trigger")=="swing" and "swing" or "contact"
    end
    -- The look-ahead's probe: the next attack's own stock box at each pose,
    -- against enemy hit zones only. Read-only: it never damages.
    local function contact_query(unit,extension,weapon,args)
        local template=weapon.weapon_template
        local settings=template.actions[args.action]
        local instance=weapon.actions and weapon.actions[args.action]
        local uses_matrix=instance and instance._uses_matrix_data
        if uses_matrix==nil then uses_matrix=type(settings and settings.sweeps)=="table" and #settings.sweeps>0 end
        local volume=settings and deps.Volume.resolve(template,settings,defaults,uses_matrix)
        if not volume or not extension._physics_world then return nil end
        local sides=Managers.state.extension:system("side_system")
        local _,reach=deps.Timing.authored_path(template,settings)
        local head=first_person(unit)
        local within=reach and head and Contact.within(head,reach*(settings.range_mod or 1)) or nil
        return deps.Contact.query({world=extension._physics_world,volume=volume,filter="filter_player_character_melee_sweep",
            attacker=unit,Probe=Probe,HitZone=require("scripts/utilities/attack/hit_zone"),within=within,
            enemy=function(other) return not (sides and sides.side_by_unit[other] and sides:is_ally(unit,other)) end},args.poses)
    end
    -- The orientation the stock input sends while a swing's attack runs.
    function presentation.melee_gesture_orientation(unit,t)
        if state.authority~="stock" or not state.runtime or unit~=state.unit then return nil end
        local extension=ScriptUnit.has_extension(unit,"weapon_system")
        local component=extension and extension._weapon_action_component
        local template=state.weapon and state.weapon.weapon_template
        local name=component and component.current_action_name
        local settings=template and template.actions and template.actions[name]
        return state.latch.current(name,settings and settings.kind,component and component.start_t,t)
    end
    function api.stop(reason)
        local runtime=state.runtime
        local orphan=not runtime and state.owner
        state.runtime=nil; state.owner=nil; state.unit=nil; api.support_held=false; state.lock=nil; state.lock_pose=nil
        if runtime then runtime.close() end
        if orphan then orphan.close() end
        visual.restore()
        if runtime then log("stopped",{reason=reason}) end
    end
    function api.update()
        local t=main_time()
        if state.poll and t>=state.poll and t-state.poll<1 then return end
        state.poll=t
        local file=Mods.lua.io.open("./../mods/darktidevr/darktidevr_physical_melee.flag","r")
        local profile
        if file then profile=(file:read(64) or ""):match("^%s*(%a+)%s*$"); file:close() end
        if profile~="auto" and profile~="knife" and profile~="sword" and profile~="axe" and profile~="hammer" then profile=nil end
        if profile~=state.profile then
            api.stop("profile_changed"); state.profile=profile; state.failed=false
            state.claimed_active=false; state.claimed_weapon=nil
            log("mode",{profile=profile or "off",authority="local_range_physical_mission_stock"})
        end
    end
    -- The physical weapon works in hilt frames; see darktidevr_melee_grip.
    local function pose(side)
        if not tracking[side.."_grip_tracking_live"] then return nil end
        return Grip.to_hilt({position={tracking[side.."_grip_x"],tracking[side.."_grip_y"],tracking[side.."_grip_z"]},
            rotation={tracking[side.."_grip_qx"],tracking[side.."_grip_qy"],tracking[side.."_grip_qz"],tracking[side.."_grip_qw"]}})
    end
    local function context(handler,input,claim)
        if not state.profile or (state.failed and not claim) or not authority() or presentation.mode~=1 or
                presentation.controllers_suppressed() or not tracking.gameplay_input_active or
                not tracking.body_anchor_qw or presentation.gameplay_context.ui_blocks_gameplay(Managers.ui) or
                not presentation.gameplay_context.input_service_enabled(input) then return nil end
        local unit=presentation.gameplay_context.local_input_unit(handler,Managers.player)
        if not unit or not Unit.alive(unit) then return nil end
        local producer=Runtime.owner(unit)
        if producer and producer~=state.runtime then return nil end
        local extension=ScriptUnit.has_extension(unit,"weapon_system")
        local slot=extension and extension._inventory_component and extension._inventory_component.wielded_slot
        local weapon=extension and extension._weapons and extension._weapons[slot]
        if slot~="slot_primary" or not weapon then return nil end
        local melee=false
        for _,settings in pairs(weapon.weapon_template and weapon.weapon_template.actions or {}) do
            if settings.kind=="windup" and settings.start_input=="start_attack" then melee=true end
        end
        if not melee then return nil end
        if not Weapons.resolve(weapon.weapon_template,state.profile) then return nil end
        return unit,extension,weapon,slot
    end
    function api.pre_fixed(handler,dt,t,frame,input)
        if not context(handler,input,true) then
            state.claimed_active=false
            if state.runtime then api.stop("context_unavailable") end
        end
    end
    function api.world_pose(value)
        if not tracking.body_anchor_qw then return nil end
        local anchor=Quaternion.from_elements(tracking.body_anchor_qx,tracking.body_anchor_qy,tracking.body_anchor_qz,tracking.body_anchor_qw)
        local player=Managers.player:local_player(1)
        local scale=presentation.calibrated_character_scale(player) or 1
        local p,q=value.position,value.rotation
        return Vector3(tracking.body_anchor_x,tracking.body_anchor_y,tracking.body_anchor_z)+
            Quaternion.rotate(anchor,Vector3(p[1]*scale,p[2]*scale,p[3]*scale)),
            Quaternion.multiply(anchor,Quaternion.from_elements(q[1],q[2],q[3],q[4]))
    end
    function api.body_pose(p,q)
        if not tracking.body_anchor_qw then return nil end
        local anchor=Quaternion.from_elements(-tracking.body_anchor_qx,-tracking.body_anchor_qy,-tracking.body_anchor_qz,tracking.body_anchor_qw)
        local player=Managers.player:local_player(1)
        local scale=presentation.calibrated_character_scale(player) or 1
        if scale<=0 then return nil end
        local local_p=Quaternion.rotate(anchor,p-Vector3(tracking.body_anchor_x,tracking.body_anchor_y,tracking.body_anchor_z))
        local x,y,z,w=Quaternion.to_elements(Quaternion.multiply(anchor,q))
        return {position={Vector3.x(local_p)/scale,Vector3.y(local_p)/scale,Vector3.z(local_p)/scale},rotation={x,y,z,w}}
    end
    local function advance(handler,dt,t,frame,input)
        local unit,extension,weapon,slot=context(handler,input)
        if not unit then api.stop("context_unavailable"); return end
        local dominant=presentation.hand_side("dominant")
        local support=presentation.hand_side("support")
        local raw=pose(dominant)
        if not raw then api.stop("tracking_unavailable"); return end
        local session=Managers.state.game_session
        local mode=authority()
        local trigger=mode=="stock" and trigger_mode() or nil
        if state.runtime and (state.weapon~=weapon or state.unit~=unit or state.session~=session or state.side~=dominant or
                state.authority~=mode or state.trigger~=trigger) then
            api.stop("weapon_or_session_changed")
        end
        if state.session~=session then state.strokes=Strokes.new() end
        if not state.runtime then
            local config,reason=Weapons.resolve(weapon.weapon_template,state.profile)
            if not config then error(reason) end
            config.library_path=options.library_path
            local owner,reason=Pose.new(Inertia,config)
            if not owner then error(reason) end
            state.owner=owner; state.unit=unit; state.weapon=weapon; state.session=session; state.slot=slot; state.side=dominant
            state.reference={}; state.recenter=nil; state.transport=nil; state.authority=mode; state.trigger=trigger; state.latch.clear()
            state.runtime=Runtime.new(deps,{source="tracking",owner=owner,strokes=state.strokes,unit=unit,
                extension=extension,weapon=weapon,slot=slot,defaults=defaults,cancel_on_adopt=mode=="physical",native_events=true,
                authority=mode,on_commit=mode=="stock" and function(data) commit_aim(unit,weapon,data) end or nil,
                contact=trigger=="contact" and function(args) return contact_query(unit,extension,weapon,args) end or nil,
                to_world=api.world_pose,to_world_direction=api.world_direction,emit=log,cancel_native=function(time)
                    if mode=="physical" and Unit.alive(unit) and extension._weapons[slot]==weapon and private() then
                        extension:stop_action("unwield",nil,time,false)
                    end
                end,freeze_world=function(p,q)
                    return {position={Vector3.x(p),Vector3.y(p),Vector3.z(p)},rotation={Quaternion.to_elements(q)}}
                end,world_components=function(value)
                    return Vector3(unpack(value.position)),Quaternion.from_elements(unpack(value.rotation))
                end,sticky_frame=function(action) return deps.Tether.native_frame(action,api.body_pose) end})
            log("started",{profile=config.profile,weapon=weapon.weapon_template.name,inertia_source=config.source,authority=mode,trigger=trigger,
                inertia_id=config.id,estimated=config.estimated or false,mass=config.body and config.body.mass,
                length=config.body and config.body.length})
        end
        if state.recenter~=tracking.head_recenter_generation or state.transport~=tracking.last_transport_generation then
            state.reference={}; state.recenter=tracking.head_recenter_generation; state.transport=tracking.last_transport_generation
        end
        local cache_index=handler:_buffer_index(frame)
        local guarding=state.guard_intent==true
        local result,reason,released=state.runtime.sample({source="tracking",active=true,tracking_valid=true,reference=state.reference,
            dominant=raw,support=pose(support),support_held=api.support_held==true and pose(support)~=nil,
            intent=true,guarding=guarding,pose_block=mod.get and mod:get("vr_pose_block")==true,
            heavy_intent=state.heavy_intent,followup_intent=state.heavy_intent,time=t,frame=frame})
        -- Pulling away from a sticky contact (a chainsword lock-on) releases
        -- that stroke only; failing here would disable physical melee, and
        -- the attack inputs it claims, until the profile changed.
        if not result and released then return end
        if not result then error(reason) end
        state.sample_main=main_time()
        -- Online lock-in: while the attack the client runs is stuck in a target
        -- (a revved chainsword or Eviscerator sawing), show the weapon held at
        -- that target; a pull of the real hand past STICKY_HOLD lets it go.
        if state.authority=="stock" then
            local instance=weapon.actions and weapon.actions[extension._weapon_action_component.current_action_name]
            local sweep=instance and instance._action_sweep_component
            local frame=sweep and sweep.is_sticky==true and deps.Tether.native_frame(instance,function(p,q)
                return {position={Vector3.x(p),Vector3.y(p),Vector3.z(p)},rotation={Quaternion.to_elements(q)}}
            end)
            local hand=frame and state.runtime.latest() and state.runtime.latest().world
            if frame and hand and (not state.lock or state.lock.action~=instance) then
                state.lock={action=instance,binding=deps.Tether.attach(frame,hand)}
                log("sticky_hold",{authority="stock",target=tostring(frame.target),node=frame.node})
            end
            local held=frame and state.lock and state.lock.action==instance and deps.Tether.resolve(state.lock.binding,frame)
            if held and hand then
                local d=0
                for axis=1,3 do d=d+(held.position[axis]-hand.position[axis])^2 end
                if math.sqrt(d)>Runtime.STICKY_HOLD then held=nil;log("sticky_yank",{authority="stock"}) end
            end
            if not held then state.lock=nil end
            state.lock_pose=held or nil
        end
        -- Lots of hand motion with no stroke: record why, at most every 3 s.
        local stall=state.stall
        if not stall or stall.runtime~=state.runtime then stall={runtime=state.runtime,since=t,travel=0}; state.stall=stall end
        local hand=raw.position
        if stall.hand then
            stall.travel=stall.travel+math.sqrt((hand[1]-stall.hand[1])^2+(hand[2]-stall.hand[2])^2+(hand[3]-stall.hand[3])^2)
        end
        stall.hand={hand[1],hand[2],hand[3]}
        local stroke=result.stroke
        if stroke and (stroke.committed or stroke.phase=="active") then stall.since=t;stall.travel=0 end
        if t-stall.since>=2 and stall.travel>=1.5 and (not stall.logged or t-stall.logged>=3) then
            local ok,special=pcall(function()
                return ScriptUnit.extension(unit,"unit_data_system"):read_component(slot).special_active
            end)
            log("motion_stall",{phase=stroke and stroke.phase,reason=stroke and stroke.reason,seconds=string.format("%.2f",t-stall.since),
                travel=string.format("%.2f",stall.travel),timing=result.timing~=nil,native_ready=result.timing and result.timing.ready,
                ready_in=result.timing and result.timing.ready_in,guarding=guarding,heavy_intent=state.heavy_intent,
                special_active=ok and tostring(special) or "unknown",action=extension._weapon_action_component.current_action_name,
                authority=state.authority})
            stall.logged=t;stall.since=t;stall.travel=0
        end
        local bindings={{"action_one",state.runtime.inputs(frame)},{"action_two",state.runtime.block_inputs(frame)}}
        if state.authority=="stock" and state.block_raw then
            -- Online the block button stays stock; the runtime only adds to it.
            local raw,own=state.block_raw,bindings[2][2]
            local held=raw.held or own.held
            bindings[2][2]={pressed=raw.pressed or own.pressed,held=held,released=not held and (raw.released or own.released)}
            -- While block is held the trigger stays stock: push and push attack.
            local edge=bindings[1][2]
            if raw.held and state.trigger_raw and not edge.pressed and not edge.held and not edge.released then
                bindings[1][2]=state.trigger_raw
            end
        end
        for _,binding in ipairs(bindings) do
            local edge=binding[2]
            for suffix,value in pairs({_pressed=edge.pressed,_hold=edge.held,_release=edge.released}) do
                local index=handler._action_lookup[binding[1]..suffix]
                if index and handler._input_cache[index] then handler._input_cache[index][cache_index]=value end
            end
        end
    end
    local function fixed_update(handler,dt,t,frame,input)
        local unit,extension,weapon=context(handler,input,true)
        state.claimed_active=unit~=nil
        state.claimed_authority=unit and authority() or nil
        if unit then
            local changed=state.claimed_weapon~=weapon or state.claimed_unit~=unit
            state.claimed_weapon=weapon; state.claimed_unit=unit; state.claimed_extension=extension
            local column=handler:_buffer_index(frame)
            local guard_index=handler._action_lookup.action_two_hold
            state.guard_intent=guard_index and handler._input_cache[guard_index][column]==true or false
            local primary_index=handler._action_lookup.action_one_hold
            state.heavy_intent=primary_index and handler._input_cache[primary_index][column]==true or false
            local function raw(binding)
                local edge={}
                for suffix,key in pairs({_pressed="pressed",_hold="held",_release="released"}) do
                    local index=handler._action_lookup[binding..suffix]
                    edge[key]=index and handler._input_cache[index] and handler._input_cache[index][column]==true or false
                end
                return edge
            end
            state.trigger_raw=raw("action_one");state.block_raw=raw("action_two")
            for _,name in ipairs({"action_one_pressed","action_one_hold","action_one_release",
                    "action_two_pressed","action_two_hold","action_two_release"}) do
                local index=handler._action_lookup[name]
                if index and handler._input_cache[index] then handler._input_cache[index][column]=false end
            end
            -- Never stop a server-run action from the client.
            if changed and state.claimed_authority=="physical" then extension:stop_action("unwield",nil,t,false) end
        end
        advance(handler,dt,t,frame,input)
    end
    function api.fixed_update(...)
        local ok,reason=pcall(fixed_update,...)
        if not ok then api.stop("error"); state.failed=true; log("error",{reason=reason}) end
    end
    function api.active()
        local age=state.sample_main and main_time()-state.sample_main
        return state.runtime and state.runtime.latest() and age and age>=0 and age<=.1 and
            not presentation.controllers_suppressed() and tracking.gameplay_input_active and
            not presentation.gameplay_context.ui_blocks_gameplay(Managers.ui) and
            state.unit and Unit.alive(state.unit) and state.session==Managers.state.game_session and
            state.recenter==tracking.head_recenter_generation and state.transport==tracking.last_transport_generation and
            tracking[presentation.hand_side("dominant").."_grip_tracking_live"] and private()
    end
    function api.world_grip(side)
        if side~="left" and side~="right" then return nil end
        -- Online lock-in: the weapon hand stays where the native sticky holds it.
        if state.authority=="stock" and state.lock_pose and side==presentation.hand_side("dominant") then
            local value=state.lock_pose
            return Vector3(unpack(value.position)),Quaternion.from_elements(unpack(Grip.from_hilt(value.rotation)))
        end
        if not api.active() then return nil end
        local current=state.runtime.latest()
        if not tracking[side.."_grip_tracking_live"] then return nil end
        local value=current.world_support
        if side==presentation.hand_side("dominant") then value=current.world end
        if value then return Vector3(unpack(value.position)),Quaternion.from_elements(unpack(Grip.from_hilt(value.rotation))) end
    end
    function api.support_request(unit,enabled)
        if state.profile and not state.failed and enabled and private() and unit then
            local producer=Runtime.owner(unit)
            if producer and producer~=state.runtime then return nil end
            local extension=ScriptUnit.has_extension(unit,"weapon_system")
            local slot=extension and extension._inventory_component and extension._inventory_component.wielded_slot
            local weapon=extension and extension._weapons and extension._weapons[slot]
            for _,settings in pairs(weapon and weapon.weapon_template and weapon.weapon_template.actions or {}) do
                if settings.kind=="windup" and settings.start_input=="start_attack" then
                    return {control=presentation.hand_side("support").."_grip",owner=api,action="unbound",layer="gripping",acquire=true,retain=true}
                end
            end
        end
    end
    function api.finish_grip(grip) api.support_held=grip and grip.held and not grip.cancelled or false end
    function api.on_start(action,settings,t)
        if state.runtime and state.runtime.on_start(action,settings,t) then state.owned[action]=state.runtime; return true end
        -- A live runtime that declines a sweep (a weapon special) leaves it stock.
        if state.runtime and state.runtime.latest() and action._player_unit==state.unit then state.stock_sweeps[action]=true; return nil end
        if state.claimed_active and state.claimed_authority=="physical" and action._player_unit==state.claimed_unit and action._weapon==state.claimed_weapon and
                not action._unit_data_extension.is_resimulating then
            state.blocked[action]=true
            action._action_sweep_component.sweep_state="during_damage_window"
            log("context_rejected",{reason="tracking_source_unavailable"}); return true
        end
    end
    function api.allow_chain(handler,chain,t)
        if state.runtime then return state.runtime.allow_chain(handler,chain,t) end
        return not (state.claimed_active and state.claimed_authority=="physical" and
            Runtime.is_followup_chain(state.claimed_extension,state.claimed_weapon,handler,chain))
    end
    function api.select_chain(handler,chain,t,...)
        if state.runtime then return state.runtime.select_chain(handler,chain,t,...) end
        return chain
    end
    function api.update_sweep(action,dt,t,_,settings)
        local runtime=state.owned[action]
        if state.blocked[action] then return true end
        if not runtime and not state.stock_sweeps[action] and state.claimed_active and state.claimed_authority=="physical" and
                action._player_unit==state.claimed_unit and action._weapon==state.claimed_weapon then
            state.blocked[action]=true; action._action_sweep_component.sweep_state="during_damage_window"; return true
        end
        if runtime and (runtime~=state.runtime or not api.active()) then runtime.invalidate("inactive_context") end
        if not runtime then return false end
        local ok,handled=pcall(runtime.update_sweep,action,dt,t,settings)
        if not ok then
            api.stop("query_error"); state.failed=true; log("error",{reason=handled}); return true
        end
        return handled
    end
    function api.on_finish(action,t)
        state.blocked[action]=nil;state.stock_sweeps[action]=nil
        local runtime=state.owned[action]
        if runtime then runtime.on_finish(action,t) end
    end
    function api.after_finish(action)
        local runtime=state.owned[action]
        if runtime then runtime.after_finish(action);state.owned[action]=nil end
    end
    function api.native_event(action,name,invoke,...)
        local runtime=state.owned[action]
        return runtime and runtime.native_event(action,name,invoke,...) or false
    end
    function api.before_hit(action,target)
        if state.blocked[action] then return false end
        local runtime=state.owned[action]
        if not runtime then return nil end
        if runtime~=state.runtime or not api.active() then return false end
        return runtime.claim(action,target)
    end
    function api.after_hit(action,aborted)
        local runtime=state.owned[action]
        if runtime then runtime.impact(aborted) end
    end
    function api.hit_direction(action)
        local runtime=state.owned[action]
        local direction=runtime and runtime.body_direction(action)
        return runtime and runtime.world_direction(action) or direction and api.world_direction(direction)
    end
    function api.world_direction(direction)
        if not tracking.body_anchor_qw then return nil end
        return Quaternion.rotate(Quaternion.from_elements(tracking.body_anchor_qx,tracking.body_anchor_qy,
            tracking.body_anchor_qz,tracking.body_anchor_qw),Vector3(direction[1],direction[2],direction[3]))
    end
    function api.apply_visual(world,unit)
        if state.authority=="stock" and state.lock_pose and unit==state.unit then
            local extension=ScriptUnit.has_extension(unit,"visual_loadout_system")
            local p,q=api.world_grip(presentation.hand_side("dominant"))
            if extension and p then visual.apply(world,extension,state.slot,{dominant={position=p,rotation=q}}) end
            return
        end
        if not api.active() or unit~=state.unit then visual.restore(); return end
        local extension=ScriptUnit.has_extension(unit,"visual_loadout_system")
        if not extension then return end
        local grips={}
        for _,role in ipairs({"dominant","support"}) do
            local p,q=api.world_grip(presentation.hand_side(role))
            if p then grips[role]={position=p,rotation=q} end
        end
        visual.apply(world,extension,state.slot,grips)
    end
    return api
end
return Tracking
