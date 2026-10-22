-- Equipment roots share the same world grip supplied to IK and collision.
-- Combined equipment containers are not physical hand pivots.
local Visual={}
local function inverse(q)
    local x,y,z,w=Quaternion.to_elements(q)
    return Quaternion.from_elements(-x,-y,-z,w)
end
local function place(unit,p,q)
    local parent_rotation=Quaternion.multiply(Unit.world_rotation(unit,1),inverse(Unit.local_rotation(unit,1)))
    local parent_position=Unit.world_position(unit,1)-Quaternion.rotate(parent_rotation,Unit.local_position(unit,1))
    Unit.set_local_position(unit,1,Quaternion.rotate(inverse(parent_rotation),p-parent_position))
    Unit.set_local_rotation(unit,1,Quaternion.multiply(inverse(parent_rotation),q))
end
function Visual.new()
    local originals={}
    local api={}
    function api.restore()
        for unit,original in pairs(originals) do
            if Unit.alive(unit) then
                Unit.set_local_position(unit,1,original.position:unbox())
                Unit.set_local_rotation(unit,1,original.rotation:unbox())
            end
        end
        originals={}
    end
    function api.apply(world,extension,slot,grips)
        local first=extension:unit_and_attachments_from_slot(slot)
        local equipment=extension._equipment and extension._equipment[slot]
        local lookup=equipment and equipment.attachment_id_lookup_1p
        local units={dominant=lookup and lookup.right or first,support=lookup and lookup.left}
        if units.support==units.dominant or units.support==first then units.support=nil end
        for _,role in ipairs({"dominant","support"}) do
            local unit,grip=units[role],grips[role]
            if unit and not grip and originals[unit] and Unit.alive(unit) then
                Unit.set_local_position(unit,1,originals[unit].position:unbox())
                Unit.set_local_rotation(unit,1,originals[unit].rotation:unbox())
                originals[unit]=nil
                World.update_unit_and_children(world,unit)
            end
            if unit and grip and Unit.alive(unit) then
                if not originals[unit] then
                    originals[unit]={position=Vector3Box(Unit.local_position(unit,1)),rotation=QuaternionBox(Unit.local_rotation(unit,1))}
                end
                place(unit,grip.position,grip.rotation); World.update_unit_and_children(world,unit)
                if Vector3.length(Unit.world_position(unit,1)-grip.position)>.001 then
                    place(unit,grip.position,grip.rotation); World.update_unit_and_children(world,unit)
                end
            end
        end
    end
    return api
end
return Visual
