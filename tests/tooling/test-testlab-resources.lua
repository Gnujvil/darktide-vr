local root=assert(arg[1])
local Resources=dofile(root..'/mods/darktide_testlab/scripts/mods/darktide_testlab/resources.lua')
local smoke='content/fx/particles/weapons/swords/chainsword/chainsword_weapon_special_activate_smoke'
local original_fx='content/fx/particles/weapons/original'
local env=setmetatable({}, {__index=_G})
env.require=function() return {weapon_special_loop={switch={'wielded_weapon_template'},particles={chainsword_p1_m1=smoke,original=original_fx}}} end
env.table=setmetatable({clear=function(t) for k in pairs(t) do t[k]=nil end end},{__index=table})
local chunk=assert(loadfile(root..'/artifacts/game-reference/player_character_particles.lua'));setfenv(chunk,env)
local NativeParticles=chunk()
local original={name='original',weapon_template='original',resource_dependencies={original_model=true}}
local candidate={name='chainsword',weapon_template='chainsword_p1_m1',resource_dependencies={candidate_model=true}}
local ctx={equipment={slot_primary={item=original,equipped=true,wieldable=true}},static_properties={breed='human'}}
local api={properties=function(equipment,slot,static)
    assert(slot=='slot_primary' and static==ctx.static_properties)
    return {wielded_weapon_template=equipment[slot].item.weapon_template}
end,particles=NativeParticles.find_relevant_particles,sounds=function() return {native_sound=true} end,
    decals=function() return {native_decal=true} end}
local next_item=Resources.item(candidate,ctx,api)
local previous=Resources.item(original,ctx,api)
assert(next_item.resource_dependencies[smoke] and not next_item.resource_dependencies[original_fx])
assert(previous.resource_dependencies[original_fx] and not previous.resource_dependencies[smoke])
assert(next_item.resource_dependencies.candidate_model and next_item.resource_dependencies.native_sound and next_item.resource_dependencies.native_decal)
assert(not candidate.resource_dependencies[smoke] and not original.resource_dependencies[original_fx])
assert(ctx.equipment.slot_primary.item==original and next_item.name==candidate.name)
assert(next_item.resource_dependencies[smoke],'native temporary resolver reuse corrupted prior package set')
print('testlab_resources=pass native_particle_alias candidate_profile FX_dependency retained_original no_owned_mutation')
