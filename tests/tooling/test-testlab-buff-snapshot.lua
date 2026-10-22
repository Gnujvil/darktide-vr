local Snapshot=dofile(assert(arg[1]))
local root=assert(arg[2])
local function read(path)
    local file=assert(io.open(root..'/'..path,'r'));local source=file:read('*a');file:close();return source
end
local buff_source=read('artifacts/game-reference/buff.lua')
local extension_source=read('artifacts/game-reference/buff_extension_base.lua')
local env={Buff={},BuffExtensionBase={}}
local function native(source)
    local chunk=assert(loadstring(source,'@cached_native_buff_snapshot_getter'));setfenv(chunk,env);chunk()
end
native(assert(buff_source:match('(Buff.stack_count = function.-\nend)')))
for _,name in ipairs({'buffs','stat_buffs','keywords'}) do
    native(assert(extension_source:match('(BuffExtensionBase%.'..name..' = function.-\nend)')))
end
local function buff(name,stack,id)
    return setmetatable({_template={name=name},_template_context={stack_count=stack},_instance_id=id,__class_name='Buff'},
        {__index=env.Buff})
end
local lazy_reads=0
local stats=setmetatable({melee_attack_speed=.1,power_level_modifier=.2,_modified_stats={melee_attack_speed=true}},
    {__index=function() lazy_reads=lazy_reads+1;error('observer indexed native lazy default') end})
local first=buff('beta',2,7)
local extension=setmetatable({_buffs={first,buff('alpha',1,8)},_stat_buffs=stats,_keywords={blocking=true,invisible=false}},
    {__index=env.BuffExtensionBase})
local capture=Snapshot.capture(extension)
assert(capture.complete and not capture.truncated and #capture.buffs==2 and capture.buffs[1].name=='alpha' and
    capture.buffs[2].stacks==2 and capture.stats.melee_attack_speed==.1 and capture.keywords.invisible==false and lazy_reads==0)
assert(capture.stats._modified_stats==nil and Snapshot.same(capture,Snapshot.capture(extension)))
extension._buffs[1],extension._buffs[2]=extension._buffs[2],extension._buffs[1]
assert(Snapshot.same(capture,Snapshot.capture(extension)),'native array compaction fabricated a buff-state change despite stable instance IDs')
first._template_context.stack_count=3;first._template.name='changed';stats.melee_attack_speed=.100000001
extension._keywords.blocking=false
assert(capture.buffs[2].name=='beta' and capture.buffs[2].stacks==2 and capture.stats.melee_attack_speed==.1 and
    capture.keywords.blocking==true,'snapshot retained mutable native tables')
assert(not Snapshot.same(capture,Snapshot.capture(extension)))
extension._buffs[3]=buff('bad_stack',nil,9)
local partial=Snapshot.capture(extension)
assert(not partial.complete and #partial.errors>0 and #partial.buffs==2,'missing native stack count fabricated zero')
extension._buffs[3]=nil
stats.power_level_modifier=0/0
partial=Snapshot.capture(extension)
assert(not partial.complete and partial.stats.power_level_modifier==nil,'nonfinite stat accepted')
stats.power_level_modifier=.2
local large=setmetatable({_buffs={},_stat_buffs={},_keywords={}},{__index=env.BuffExtensionBase})
for i=1,257 do large._buffs[i]=buff('buff_'..i,1,i);large._keywords['keyword_'..i]=true end
for i=1,513 do large._stat_buffs['stat_'..i]=i end
local bounded=Snapshot.capture(large)
local count=0;for _ in pairs(bounded.stats) do count=count+1 end
assert(not bounded.complete and bounded.truncated and #bounded.buffs==256 and count==512,'snapshot bound failed')
assert(not Snapshot.same(bounded,bounded),'partial snapshots claimed equivalent complete state')
local missing=Snapshot.capture(nil)
assert(not missing.complete and #missing.errors==3,'missing extension claimed known empty buffs')
large.buffs=function() error('native getter failure') end
bounded=Snapshot.capture(large)
assert(not bounded.complete and #bounded.buffs==0 and next(bounded.stats),'one failed getter discarded unrelated native state')
assert(lazy_reads==0 and first._template_context.stack_count==3 and stats.melee_attack_speed==.100000001,
    'observer mutated native state/defaults')
print('testlab_buff_snapshot=pass actual_native_getters bounded_templates_stacks_materialized_stats_keywords no_lazy_defaults detached_scalars partial_unknown no_silent_zero equality_change_detection')
