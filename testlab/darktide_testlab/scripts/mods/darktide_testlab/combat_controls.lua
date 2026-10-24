-- A local test shortcut, separate from gameplay bindings. Individual stick
-- clicks retain their bindings; the simultaneous chord is consumed to release.
local Controls={}
local bit=require("bit")
function Controls.new(toggle,allowed,on_tap)
    local state={}
    return {sample=function(held,active,t)
        held=tonumber(held) or 0
        if type(t)~="number" or t~=t or t==math.huge or t==-math.huge then state={};return held end
        local clicks=bit.band(held,384)
        local continuous=state.t and t>=state.t and t-state.t<=.15
        state.t=t
        if not active or not allowed() or not continuous then
            state.armed=false;state.claimed=false;state.start=nil;state.fired=false
            return held
        end
        if clicks==0 then
            if state.claimed and not state.fired and state.start and t-state.start<.4 and on_tap then on_tap() end
            state.armed=true;state.claimed=false;state.start=nil;state.fired=false
        elseif clicks==384 and state.armed and not state.claimed then
            state.claimed=true;state.start=t;state.armed=false
        end
        if state.claimed then
            if clicks~=384 then state.start=nil end
            if state.start and not state.fired and t-state.start>=.4 then
                state.fired=true;toggle()
            end
            return bit.band(held,bit.bnot(384))
        end
        return held
    end}
end
return Controls
