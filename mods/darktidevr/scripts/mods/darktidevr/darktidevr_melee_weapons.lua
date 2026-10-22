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
function Weapons.resolve(template,override)
    if override and override~='auto' then
        if override~='knife' and override~='sword' and override~='axe' and override~='hammer' then return nil,'unknown_profile' end
        return {profile=override,id='override:'..override,source='explicit_profile_override'}
    end
    local name=type(template)=='table' and template.name
    local entry=name and entries[name]
    if not entry then return nil,'unmapped_weapon_template' end
    return {profile=entry.profile,body={mass=entry.mass,length=entry.length,head_fraction=entry.head_fraction},
        id=name,source='stock_template_tuning_v1',estimated=true}
end
return Weapons
