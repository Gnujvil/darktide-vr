-- Execute cached native sticky timer/update code with engine boundaries mocked.
-- Attack counters here are NOT actual health, proc, visual or installed-game proof.
local root=assert(arg[1])
local function read(name)
    local f=assert(io.open(root..'/artifacts/game-reference/'..name,'r'))
    local text=f:read('*a');f:close();return text
end
local source=read('action_sweep.lua')
local update=assert(source:match('(ActionSweep%._update_hit_stickyness = function.-)\nActionSweep%._handle_stickyness'),'native update moved')
for _,mode in ipairs({'natural','dodge','jump','target_removed','resim'}) do
    local target,actor,position={},{},{}
    local profiles,stops,drains={},0,0
    local env={ActionSweep={},math=setmetatable({round_with_precision=function(value,digits)
            local factor=10^digits;return math.floor(value*factor+.5)/factor
        end},{__index=math}),Managers={state={game_session={fixed_time_step=.02}}},ALIVE={[target]=true},
        Unit={actor=function() return actor end,world_position=function() return position end},
        Actor={node=function() return 72 end},HitZone={get_name=function() return 'torso' end},
        Vector3={normalize=function(v) return v end,flat=function(v) return v end},
        Quaternion={forward=function() return position end},DEFAULT_POWER_LEVEL=500,
        AttackSettings={attack_types={melee='melee'}},attack_results={died='died'},buff_keywords={invisible='invisible'},
        ImpactEffect={play=function() end},Stamina={drain_pecentage_of_base_stamina=function() drains=drains+1 end},
        Attack={execute=function(_,profile) profiles[#profiles+1]=profile;return 5,'damaged',1,nil,false end}}
    local helper=assert(loadstring(read('sweep_stickyness.lua'),'@native_sticky_timing'))
    setfenv(helper,env);env.SweepStickyness=helper()
    local chunk=assert(loadstring(update..'\nreturn ActionSweep._update_hit_stickyness','@native_sticky_update'))
    setfenv(chunk,env);local native=chunk()
    local component={is_sticky=true,sweep_aborted_unit=target,sweep_aborted_actor_index=1,sweep_aborted_t=0,attack_direction=position}
    local settings={duration=1,min_sticky_time=.5,damage={instances=3,damage_profile='tick',last_damage_profile='last',dodge_damage_profile='dodge'}}
    local action={_is_server=true,_action_sweep_component=component,_first_person_unit={},_unit_data_extension={is_resimulating=mode=='resim'},
        _critical_strike_component={},_player={player_unit={}},_player_unit={},_weapon={item={}},_first_person_component={position=position,rotation={}},
        _action_settings={},_character_state_component={state_name='walking',entered_t=0},_buff_extension={has_keyword=function() return false end},
        _handle_stickyness=function() end,_stop_hit_stickyness=function(_,_,early) stops=stops+1;component.is_sticky=false end}
    local ended
    for frame=0,60 do
        local t=frame*.02
        if t>=.5 and (mode=='dodge' or mode=='jump') then
            action._character_state_component.state_name=mode=='dodge' and 'dodging' or 'jumping'
            action._character_state_component.entered_t=.5
        end
        if t>=.4 and mode=='target_removed' then env.ALIVE[target]=false end
        native(action,.02,t,component,settings)
        if not component.is_sticky then ended=t;break end
    end
    assert(stops==1 and ended,'native sticky never retired')
    if mode=='natural' then assert(#profiles==3 and profiles[1]=='tick' and profiles[3]=='last' and ended==1 and drains==0)
    elseif mode=='dodge' then assert(#profiles==2 and profiles[2]=='dodge' and ended==.5 and drains==1)
    elseif mode=='jump' or mode=='target_removed' then assert(#profiles==1 and ended==.5 and drains==0)
    else assert(#profiles==0 and ended==1 and drains==0,'resimulation authored native damage') end
end
print('melee_native_sticky=pass cached_native_timer natural_final_tick dodge_profile_stamina jump target_removed resimulation; NOT live damage/proc/worn proof')
