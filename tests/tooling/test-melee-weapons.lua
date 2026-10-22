local root=assert(arg[1])
local prefix=root..'/mods/darktidevr/scripts/mods/darktidevr/darktidevr_melee_'
local Weapons,Inertia,Volume=dofile(prefix..'weapons.lua'),dofile(prefix..'inertia.lua'),dofile(prefix..'volume.lua')
local library=root..'/build/melee-inertia/darktidevr_melee_inertia.dll'
local pose={position={0,0,1},rotation={-.7071067811865475,0,0,.7071067811865475}}
local support={position={0,.2,1},rotation=pose.rotation}
local observed={}
for _,name in ipairs({'combatknife_p1_m1','combatsword_p3_m3','combataxe_p2_m2','chainaxe_p1_m2',
    'chainsword_2h_p1_m1','forcesword_p1_m3','powermaul_shield_p1_m2','thunderhammer_2h_p1_m1','ogryn_club_p2_m3'}) do
    local template={name=name,weapon_box={.15,.65,.15},actions={}}
    local config=assert(Weapons.resolve(template,'auto'))
    assert(config.id==name and config.estimated and config.source=='stock_template_tuning_v1')
    local original=config.body.mass
    config.body.mass=99
    config=assert(Weapons.resolve(template))
    assert(config.body.mass==original,'mutable caller corrupted registry')
    config.library_path=library
    local solver=assert(Inertia.new(config))
    local reference={}
    local request={dominant=pose,support=support,support_held=true,time=0,tracking_valid=true,reference=reference}
    assert(solver.update(request).reset)
    request.time=.01
    local first=assert(solver.update(request))
    assert(math.abs(first.mass-original)<1e-10 and first.support_engaged)
    request.support_held=false;request.time=.02
    local released=assert(solver.update(request))
    assert(math.abs(released.mass-original)<1e-10 and not released.support_engaged,'grip changed steel mass')
    for frame=3,120 do request.time=frame/100;assert(solver.update(request)) end
    observed[name]=assert(solver.update(request)).position_lag
    solver.close()
    local volume=assert(Volume.resolve(template,{}, {sweep_width_mod=1,sweep_height_mod=1,sweep_range_mod=1},false))
    assert(volume.half_extents[2]==.65 and template.weapon_box[2]==.65,'inertia tuning changed native collision box')
end
assert(observed.thunderhammer_2h_p1_m1>observed.combatknife_p1_m1,'stock map lost inertial distinction')
assert(not Weapons.resolve({name='combatknife_p1_m999'}))
assert(not Weapons.resolve({name='autogun_p1_m1'}))
assert(not Weapons.resolve({name='dual_shivs_p1_m1'}),'dual independent weapons silently treated as one body')
assert(not Weapons.resolve(nil))
local override=assert(Weapons.resolve({name='unmapped'},'hammer'))
assert(override.source=='explicit_profile_override' and not override.body and not override.estimated)
for _,body in ipairs({{mass=0,length=1,head_fraction=.5},{mass=1,length=0,head_fraction=.5},
    {mass=1,length=1,head_fraction=1},{mass=0/0,length=1,head_fraction=.5},{mass='1',length=1,head_fraction=.5}}) do
    assert(not Inertia.new({profile='hammer',body=body,library_path=library}),'invalid configuration accepted')
end
print('melee_weapons=pass stock_registry real_DLL_mass grip_mass_invariant native_geometry_unchanged unknown_refused explicit_override provisional_estimates')
