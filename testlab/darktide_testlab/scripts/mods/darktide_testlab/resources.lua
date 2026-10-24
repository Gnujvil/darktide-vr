-- Item-preview dependencies alone omit profile-selected gameplay FX aliases.
-- Build a package-only proxy; never alter the owned item passed to native equip.
local Resources={}
function Resources.item(item,context,api)
    local equipment={}
    for name,slot in pairs(context.equipment) do equipment[name]=slot end
    local primary={}
    for key,value in pairs(assert(equipment.slot_primary)) do primary[key]=value end
    primary.item=item;primary.equipped=true;primary.wieldable=true
    equipment.slot_primary=primary
    local properties=api.properties(equipment,'slot_primary',context.static_properties)
    local dependencies={}
    for name,value in pairs(assert(item.resource_dependencies,'item_dependencies_missing')) do dependencies[name]=value end
    -- Native resolvers reuse temporary tables. Consume each before the next call.
    for _,resolve in ipairs({api.particles,api.sounds,api.decals}) do
        for name in pairs(resolve(properties)) do dependencies[name]=true end
    end
    return setmetatable({resource_dependencies=dependencies},{__index=item})
end
return Resources
