local Observations=dofile(assert(arg[1]))
local player,enemy={},{}
local context={unit=player}
local health,toughness,stamina=100,50,1
local events={}
local fail_read,fail_report
local api=Observations.new({
    identity=function(_,unit) return unit==player and 'player' or 'enemy' end,
    read=function() if fail_read then error('read failure') end;return {health=health,toughness=toughness,stamina=stamina} end,
    report=function(_,record) events[#events+1]=record;if fail_report then error('log failure') end end})
local profile={name='native_profile'}
local calls=0
local function blocked(target,p,...)
    calls=calls+1
    assert(target==player and p==profile and select('#',...)==4)
    local key,value,other,kind=...
    assert(key=='attacking_unit' and value==enemy and other=='attack_type' and kind=='melee')
    stamina=.75;return 0,'blocked',nil,3,false,nil
end
local values={n=0}
local function capture(...) values={n=select('#',...),...} end
capture(api.attack(blocked,context,player,profile,'attacking_unit',enemy,'attack_type','melee'))
assert(calls==1 and values.n==6 and values[2]=='blocked' and values[3]==nil and values[4]==3 and values[5]==false)
local record=events[#events]
assert(record.incoming and record.health_valid and record.health_delta==0 and record.toughness_delta==0 and record.stamina_delta==.25)
api.attack(function() health=82;toughness=30;return 999,'damaged' end,context,player,profile)
record=events[#events]
assert(record.damage_return==999 and record.health_delta==18 and record.toughness_delta==20,'returned prediction replaced observed health')
fail_read=true;fail_report=true
capture(api.attack(function() calls=calls+1;return nil,'predicted',nil end,context,player,profile))
assert(values.n==3 and values[2]=='predicted' and not events[#events].health_valid,'failed samples invented resource change')
assert(not pcall(api.attack,function() error('native attack failure') end,context,player,profile),'native failure swallowed')
fail_read=false;fail_report=false;health=math.huge
api.attack(function() end,context,player,profile)
assert(not events[#events].health_valid,'infinite health accepted')
local extension={_unit=player,_num_proc_events=2}
local params={attacking_unit=enemy,attacked_unit=player,damage=5,actual_damage_dealt=3}
capture(api.proc(function(self,event,p,extra)
    assert(self==extension and event=='on_block' and p==params and extra==42)
    self._num_proc_events=4;p.damage=777;return nil,false,nil
end,context,extension,'on_block',params,42))
record=events[#events]
assert(values.n==3 and values[2]==false and record.queued and record.damage==5 and record.actual_damage==3,
    'proc queue arguments/returns or pre-mutation snapshot lost')
api.proc(function() end,context,extension,'on_block',params)
assert(not events[#events].queued,'unchanged queue claimed buff application')
do
    local initial=#events
    local calls=0
    api.proc(function(self,event,p)
        return api.proc(function(owner,kind,value)
            calls=calls+1;assert(owner==extension and kind==event and value==p)
            owner._num_proc_events=owner._num_proc_events+1;return nil,'native',nil
        end,context,self,event,p)
    end,context,extension,'copied_hook',params)
    assert(calls==1 and #events==initial+1,'copied inherited hook produced duplicate queue observation')
    local failure={native_error=true}
    local ok,err=pcall(api.proc,function() error(failure) end,context,extension,'error',params)
    assert(not ok and err==failure,'native error object changed')
    initial=#events
    api.proc(function(self) self._num_proc_events=self._num_proc_events+1 end,context,extension,'error',params)
    assert(#events==initial+1,'error stranded the observation guard')
    initial=#events
    api.proc(function(self,event,p)
        api.proc(function(owner) owner._num_proc_events=owner._num_proc_events+1 end,context,self,'nested_other',{})
        self._num_proc_events=self._num_proc_events+1
    end,context,extension,'outer',params)
    assert(#events==initial+2,'different nested native event was dropped')
end
print('testlab_observations=pass native_once exact_args nil_returns prediction_vs_health blocked_resources unknown_samples proc_queue_not_effect errors_passthrough')
