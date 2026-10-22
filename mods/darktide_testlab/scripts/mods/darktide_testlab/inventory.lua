-- Read-only inventory discovery. A result belongs to one local player/session;
-- asynchronous responses never become permission to alter a later character.
local Inventory={}
function Inventory.new(options)
    local generation=0
    local catalog,owner
    local api={}
    function api.cancel() generation=generation+1;catalog=nil;owner=nil end
    function api.lookup(id)
        return catalog and owner and options.same_context(owner) and catalog[id] or nil
    end
    function api.fetch(id)
        local context=assert(options.context(),"local inventory context unavailable")
        generation=generation+1
        catalog=nil;owner=nil
        local request=generation
        local function current() return generation==request and options.same_context(context) end
        local function failed(err)
            if current() then options.emit(id,"inventory_error",tostring(err)) end
        end
        local ok,err=pcall(function()
            options.fetch(context):next(function(items)
                if not current() then return end
                local success,failure=pcall(function()
                    assert(type(items)=="table","invalid_inventory_result")
                    local rows={}
                    for gear_id,item in pairs(items) do
                        assert(#rows<512,"inventory_limit")
                        rows[#rows+1]=options.describe(gear_id,item)
                    end
                    table.sort(rows)
                    catalog=items;owner=context
                    for _,row in ipairs(rows) do options.emit(id,"inventory_item",row) end
                    options.emit(id,"inventory_ready","items="..#rows.." slots=slot_primary,slot_secondary source=owned_inventory read_only=true eligibility=unverified")
                end)
                if not success then failed(failure) end
            end):catch(failed)
        end)
        if not ok then failed(err) end
    end
    return api
end
return Inventory
