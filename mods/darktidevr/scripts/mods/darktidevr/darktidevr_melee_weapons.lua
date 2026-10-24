-- Explicit stock-template tuning. Values are provisional gameplay estimates,
-- not measured/lore masses. Native per-action collision volumes, damage and
-- attack timing remain authoritative and are never derived from these values.
local Weapons={}
local entries={}
local function add(prefix,variants,profile,mass,length,head)
    for variant in variants:gmatch('%S+') do
        entries[prefix..'_'..variant]={profile=profile,mass=mass,length=length,head_fraction=head}
    end
end
add('combatknife','p1_m1 p1_m2','knife',.2,.30,.10)
add('combatsword','p1_m1 p1_m2 p1_m3 p2_m1 p2_m2 p2_m3 p3_m1 p3_m2 p3_m3','sword',.5,.95,.10)
add('combataxe','p1_m1 p1_m2 p1_m3 p2_m1 p2_m2 p2_m3 p3_m1 p3_m2 p3_m3','axe',.8,.80,.45)
add('chainaxe','p1_m1 p1_m2','axe',1.1,.85,.55)
add('chainsword','p1_m1 p1_m2','sword',.9,1.0,.20)
add('chainsword_2h','p1_m1 p1_m2','sword',1.5,1.25,.25)
add('forcesword','p1_m1 p1_m2 p1_m3','sword',.6,1.0,.12)
add('forcesword_2h','p1_m1 p1_m2','sword',1.2,1.30,.15)
add('powersword','p1_m1 p1_m2 p2_m1 p2_m2 p3_m1','sword',.8,1.0,.15)
add('powermaul','p1_m1 p1_m2 p2_m1 p3_m1','hammer',1.2,.85,.65)
add('powermaul_2h','p1_m1 p1_m2','hammer',1.7,1.25,.65)
add('powermaul_shield','p1_m1 p1_m2','hammer',1.4,.85,.65)
add('thunderhammer_2h','p1_m1 p1_m2','hammer',2.1,1.30,.70)
add('ogryn_combatblade','p1_m1 p1_m2 p1_m3','axe',1.1,.80,.25)
add('ogryn_club','p1_m1 p1_m2 p1_m3 p2_m1 p2_m2 p2_m3','hammer',1.8,1.05,.55)
-- Templates the live 1.13.4 game has and this map lacked: an unmapped melee
-- weapon gets no tracked swings at all (PC run fastH, 22 October: the ogryn's
-- pickaxe, power maul, slab shield and two-handed hammer did nothing).
add('ogryn_pickaxe_2h','p1_m1 p1_m2 p1_m3','hammer',2.4,1.45,.75)
add('ogryn_powermaul','p1_m1','hammer',2.0,1.10,.60)
add('ogryn_powermaul_slabshield','p1_m1 p1_m2','hammer',2.0,1.05,.60)
add('ogryn_hammer_2h','p1_m1','hammer',2.6,1.45,.75)
add('crowbar','p1_m1','axe',.9,.85,.30)
add('powersword_2h','p1_m1 p1_m2','sword',1.4,1.30,.15)
add('saw','p1_m1','sword',.9,.90,.20)
add('transonic_knife','p1_m1','knife',.25,.32,.10)
add('transonic_sword','p1_m1','sword',.7,.95,.12)
-- Dual weapons: a blade in each hand, two independent bodies, so the second
-- hand has its own body (off) and swings on its own (user, 22 October: "swings
-- should work with both hands"). The first body is the weapon hand's (the
-- right weapon attach): the transonic pair's sword, its knife in the other.
local function add_dual(prefix,variants,first,second)
    for variant in variants:gmatch('%S+') do
        entries[prefix..'_'..variant]={profile=first[1],mass=first[2],length=first[3],head_fraction=first[4],
            off={profile=second[1],mass=second[2],length=second[3],head_fraction=second[4]}}
    end
end
add_dual('dual_shivs','p1_m1 p1_m2',{'knife',.2,.28,.10},{'knife',.2,.28,.10})
add_dual('transonic_sword_transonic_knife','p1_m1',{'sword',.7,.95,.12},{'knife',.25,.32,.10})
function Weapons.resolve(template,override)
    if override and override~='auto' then
        if override~='knife' and override~='sword' and override~='axe' and override~='hammer' then return nil,'unknown_profile' end
        return {profile=override,id='override:'..override,source='explicit_profile_override'}
    end
    local name=type(template)=='table' and template.name
    local entry=name and entries[name]
    if not entry then return nil,'unmapped_weapon_template' end
    local off=entry.off and {profile=entry.off.profile,id=name..':off',source='stock_template_tuning_v1',estimated=true,
        body={mass=entry.off.mass,length=entry.off.length,head_fraction=entry.off.head_fraction}}
    return {profile=entry.profile,body={mass=entry.mass,length=entry.length,head_fraction=entry.head_fraction},
        id=name,source='stock_template_tuning_v1',estimated=true,off=off}
end
return Weapons
