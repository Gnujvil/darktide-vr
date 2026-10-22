-- Copy bounded native state without adding buffs, computing stat defaults,
-- changing stacks, or retaining engine-owned/mutable result tables.
local Snapshot={}
local function finite(value) return type(value)=='number' and value==value and math.abs(value)<math.huge end
function Snapshot.capture(extension)
    local result={buffs={},stats={},keywords={},errors={},complete=true,truncated=false}
    local function problem(message)
        result.complete=false;result.errors[#result.errors+1]=message
    end
    local function source(method)
        local ok,value=pcall(function()
            assert(extension and type(extension[method])=='function','getter_unavailable')
            return extension[method](extension)
        end)
        if ok and type(value)=='table' then return value end
        problem(method..':'..tostring(value));return {}
    end
    local function copy(map,limit,fn,label)
        local count=0
        for key,value in pairs(map) do
            count=count+1
            if count>limit then result.truncated=true;problem(label..':limit');break end
            local ok,err=pcall(fn,key,value)
            if not ok then problem(label..':'..tostring(err)) end
        end
    end
    copy(source('buffs'),256,function(index,buff)
        assert(finite(index) and index>=1 and index==math.floor(index),'invalid_buff_index')
        assert(type(buff)=='table','invalid_buff')
        local template=buff._template
        local name=template and template.name or buff._template_name
        assert(type(name)=='string' and #name<=256,'template_name_unavailable')
        local stacks=buff:stack_count()
        assert(finite(stacks) and stacks>=0,'stack_count_unavailable')
        local id=buff._instance_id
        if not (finite(id) or type(id)=='string') then id=nil end
        result.buffs[#result.buffs+1]={name=name,stacks=stacks,index=index,instance_id=id,buff_class=tostring(buff.__class_name or 'unavailable')}
    end,'buffs')
    table.sort(result.buffs,function(a,b)
        if a.name~=b.name then return a.name<b.name end
        return tostring(a.instance_id or a.index)<tostring(b.instance_id or b.index)
    end)
    -- pairs reads only currently materialized fields. Indexing a stat by name
    -- can populate native lazy defaults, which an observer must not do.
    copy(source('stat_buffs'),512,function(key,value)
        if type(key)=='string' and type(value)=='number' then
            assert(finite(value),'nonfinite_stat:'..key);result.stats[key]=value
        end
    end,'stats')
    copy(source('keywords'),256,function(key,value)
        if type(key)=='string' and type(value)=='boolean' then result.keywords[key]=value end
    end,'keywords')
    return result
end
function Snapshot.same(a,b)
    if not a or not b or not a.complete or not b.complete or #a.buffs~=#b.buffs then return false end
    for index,buff in ipairs(a.buffs) do
        local other=b.buffs[index]
        for _,key in ipairs({'name','stacks','instance_id','buff_class'}) do
            if buff[key]~=other[key] then return false end
        end
        if buff.instance_id==nil and buff.index~=other.index then return false end
    end
    for _,key in ipairs({'stats','keywords'}) do
        for name,value in pairs(a[key]) do if b[key][name]~=value then return false end end
        for name,value in pairs(b[key]) do if a[key][name]~=value then return false end end
    end
    return true
end
return Snapshot
