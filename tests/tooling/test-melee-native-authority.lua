-- Execute the actual cached native damage commit gate. This proves the source
-- branch, not remote gameplay compatibility or an installed-build certificate.
local root=assert(arg[1])
local f=assert(io.open(root..'/artifacts/game-reference/attack.lua','r'))
local source=f:read('*a');f:close()
local native=assert(source:match('(function _handle_attack.-)\nfunction _already_procced'),'native gate moved')
for _,mode in ipairs({'client_prediction','server_commit','server_denied'}) do
    local health,calls=100,0
    local env={Block={is_blocking=function() return false end},Breed={is_player=function() return false end},
        attack_results={died='died'},DamageTakenCalculation={
            calculation_parameters=function() return false,mode~='server_denied' end,
            calculate_attack_result=function() return 'damaged',20,0,0,0 end},
        Damage={deal_damage=function() calls=calls+1;health=health-20;return 20 end}}
    local chunk=assert(loadstring(native..'\nreturn _handle_attack','@native_attack_commit_gate'))
    setfenv(chunk,env)
    local handle=chunk()
    local result,predicted,_,_,_,_,actual=handle(mode~='client_prediction',false,false,false,{},nil,20,{}, {},'torso',{}, {},{},'melee',nil,false,{},'slash',nil,nil,nil,nil,nil,nil,1)
    assert(result=='damaged' and predicted==20,'fixture missed predictive damage path')
    if mode=='server_commit' then assert(calls==1 and health==80 and actual==20)
    else assert(calls==0 and health==100 and actual==nil,'prediction/denial mutated authoritative health') end
end
print('melee_native_authority=pass cached_native_commit_gate client_prediction_is_not_actual_damage server_only_commit; NOT remote support proof')
