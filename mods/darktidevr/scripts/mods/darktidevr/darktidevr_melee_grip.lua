-- Tracked controller grip <-> physical weapon hilt, both body-local.
-- The OpenXR grip's -Z runs through the closed fist from little finger to
-- thumb, the way a held blade leaves the hand; in the Darktide basis that is
-- local +Y. The physical weapon (native inertia body, sweep box, guard) uses
-- local +Z as its shaft, so a grip turns -90 degrees about its own X on the
-- way in and back on the way out to the rendered hand. Without this the
-- weapon ran back along the forearm: Touch places local +Z 150 degrees from
-- the aim ray.
local Grip={}
local half=math.sqrt(.5)
local TO_HILT={-half,0,0,half}
local FROM_HILT={half,0,0,half}
local function multiply(a,b)
    return {a[4]*b[1]+a[1]*b[4]+a[2]*b[3]-a[3]*b[2],
        a[4]*b[2]-a[1]*b[3]+a[2]*b[4]+a[3]*b[1],
        a[4]*b[3]+a[1]*b[2]-a[2]*b[1]+a[3]*b[4],
        a[4]*b[4]-a[1]*b[1]-a[2]*b[2]-a[3]*b[3]}
end
function Grip.to_hilt(pose)
    if not pose then return nil end
    return {position=pose.position,rotation=multiply(pose.rotation,TO_HILT)}
end
function Grip.from_hilt(rotation) return multiply(rotation,FROM_HILT) end
return Grip
