-- One native held-body state per wielded weapon. All poses are numeric arrays
-- in the SAME tracking/body frame; callers transform the returned pose once
-- for both presentation and collision. No world-space locomotion filtering.
local ffi=Mods and Mods.lua and Mods.lua.ffi or require("ffi")
ffi.cdef[[
int dtvr_melee_abi(void);
void* dtvr_melee_create(int profile);
void* dtvr_melee_create_config(int profile,double mass,double length,double head_fraction);
void dtvr_melee_destroy(void* state);
int dtvr_melee_step(void* state,const double* dominant7,const double* support7,
    double time,double recovery,int support_held,int tracking_valid,
    unsigned int reference_generation,double* output20);
int dtvr_melee_contact(void* state,double retention);
int dtvr_melee_support_pose(void* state,double* output7);
int dtvr_melee_pin(void* state,const double* pose7,double* output20);
]]
local Inertia={}
local profiles={knife=0,sword=1,axe=2,hammer=3}
local function finite(n) return type(n)=="number" and n==n and math.abs(n)<math.huge end
local function copy_pose(buffer,pose)
    if type(pose)~="table" or type(pose.position)~="table" or type(pose.rotation)~="table" then return false end
    for i=1,3 do if not finite(pose.position[i]) then return false end; buffer[i-1]=pose.position[i] end
    for i=1,4 do if not finite(pose.rotation[i]) then return false end; buffer[i+2]=pose.rotation[i] end
    return true
end
function Inertia.new(options)
    options=options or {}
    local profile=profiles[options.profile or "sword"]
    if profile==nil then return nil,"unknown_profile" end
    local ok,library=pcall(ffi.load,options.library_path or "./../mods/darktidevr/bin/darktidevr_melee_inertia.dll")
    if not ok then return nil,"native_library_unavailable: "..tostring(library) end
    local abi_ok,abi=pcall(function() return library.dtvr_melee_abi() end)
    if not abi_ok or abi~=4 then return nil,"native_abi_mismatch" end
    local config=options.body
    if config and (type(config)~="table" or not finite(config.mass) or not finite(config.length) or not finite(config.head_fraction)) then
        return nil,"invalid_body_config"
    end
    local native=config and library.dtvr_melee_create_config(profile,config.mass,config.length,config.head_fraction) or
        library.dtvr_melee_create(profile)
    if native==nil then return nil,"native_create_failed" end
    local handle=ffi.gc(native,function(pointer) library.dtvr_melee_destroy(pointer) end)
    local dominant,support,output=ffi.new("double[7]"),ffi.new("double[7]"),ffi.new("double[20]")
    local support_pose=ffi.new("double[7]")
    local reference,generation=nil,0
    local api={}
    function api.reset()
        if not handle then return false end
        library.dtvr_melee_step(handle,dominant,support,0,1,0,0,generation,output)
        reference=nil
        return true
    end
    function api.update(request)
        if not handle then return nil,"closed" end
        request=request or {}
        local recovery=request.recovery
        if recovery==nil then recovery=1 end
        local valid=request.tracking_valid==true and request.reference~=nil and
            finite(request.time) and finite(recovery) and copy_pose(dominant,request.dominant)
        local support_valid=copy_pose(support,request.support)
        local held=request.support_held==true
        valid=valid and (not held or support_valid)
        if valid and request.reference~=reference then
            reference=request.reference; generation=(generation+1)%4294967296
        end
        local status=library.dtvr_melee_step(handle,dominant,support_valid and support or nil,
            finite(request.time) and request.time or 0,finite(recovery) and recovery or 1,
            held and 1 or 0,valid and 1 or 0,generation,output)
        if status==0 then reference=nil; return nil,"tracking_or_pose_invalid" end
        local result={position={},rotation={},linear_velocity={},angular_velocity={},
            mass=tonumber(output[13]),position_lag=tonumber(output[14]),angular_lag=tonumber(output[15]),
            recovery=tonumber(output[16]),support_engaged=output[17]~=0,reset_reason=tonumber(output[18]),
            time=tonumber(output[19]),reset=status==2,repeated=status==3}
        for i=1,3 do
            result.position[i]=tonumber(output[i-1])
            result.linear_velocity[i]=tonumber(output[i+6])
            result.angular_velocity[i]=tonumber(output[i+9])
        end
        for i=1,4 do result.rotation[i]=tonumber(output[i+2]) end
        if library.dtvr_melee_support_pose(handle,support_pose)==1 then
            result.support={position={},rotation={}}
            for i=1,3 do result.support.position[i]=tonumber(support_pose[i-1]) end
            for i=1,4 do result.support.rotation[i]=tonumber(support_pose[i+2]) end
        end
        return result
    end
    function api.contact(retention)
        return handle~=nil and finite(retention) and library.dtvr_melee_contact(handle,retention)==1
    end
    function api.pin(pose)
        if not handle or not copy_pose(support_pose,pose) then return nil,"invalid_constraint_pose" end
        if library.dtvr_melee_pin(handle,support_pose,output)==0 then return nil,"constraint_separation" end
        return true
    end
    function api.close()
        if not handle then return false end
        local pointer=handle; handle=nil
        ffi.gc(pointer,nil); library.dtvr_melee_destroy(pointer)
        return true
    end
    return api
end
return Inertia
