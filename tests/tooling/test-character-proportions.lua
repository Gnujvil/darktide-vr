-- The player's proportions on a larger character. The camera's standing
-- height is in the character's units: an ogryn's world shrinks to the player
-- (character scale above 1), so its eyes sit at the calibrated height times
-- that scale; a human's (scale 1) at the calibrated height. Worn, 23 October:
-- unscaled, the ogryn looked out from its belly. And a broader avatar's
-- shoulders narrow to the player's, so its arms start where the player's do.
-- Usage: luajit test-character-proportions.lua <darktidevr.lua>
local file = assert(io.open(assert(arg[1]), 'rb')); local main = file:read('*a'); file:close()
local function slice(first_marker, last_marker)
    local first = assert(main:find(first_marker, 1, true), first_marker)
    local tail = assert(main:find(last_marker, first, true), last_marker)
    local last = assert(main:find('\nend', tail, true))
    return main:sub(first, last + 4)
end
local source = slice('function presentation.calibrated_eye_height()',
    'return Vector3(Vector3.x(position), Vector3.y(position), Vector3.z(Unit.world_position(unit, 1)) + height)') .. '\n' ..
    slice('function presentation.calibrated_character_scale(local_player)', '"profile_relative_fallback", target_eye_height, nil') .. '\n' ..
    slice('function presentation.shoulder_narrowing(', 'return factor, width, (inner + out * factor) * 2')

local function V(x, y, z) return {x, y, z} end
local Vector3 = setmetatable({x = function(v) return v[1] end, y = function(v) return v[2] end, z = function(v) return v[3] end},
    {__call = function(_, x, y, z) return V(x, y, z) end})
local root = V(0, 0, 10)
local Unit = {alive = function() return true end, world_position = function() return root end}
local crouch = 1
local ScriptUnit = {has_extension = function()
    return {_heights = {default = 1}, extrapolated_character_height = function() return crouch end}
end}
local calibration = {floor_eye_height = 1.81, seated = false}
local mod = {get = function(_, key) assert(key == 'vr_calibration_v1'); return calibration end}
local archetype, height = 'veteran', 1.015
local player = {archetype_name = function() return archetype end,
    profile = function() return {character_height = height, archetype = {breed = archetype == 'ogryn' and 'ogryn' or 'human'}} end}
local Managers = {player = {local_player = function() return player end}}
local breeds = {human = {heights = {default = 1.65 / 1.015}, size_variation_range = {0.95, 1.08}},
    ogryn = {heights = {default = 2.2 / 0.9125}, size_variation_range = {0.9, 0.925}}}
local presentation = {}
local env = setmetatable({presentation = presentation, mod = mod, Managers = Managers, Unit = Unit, Vector3 = Vector3,
    ScriptUnit = ScriptUnit, require = function(path) assert(path == 'scripts/settings/breed/breeds'); return breeds end},
    {__index = _G})
assert(load(source, 'eye_height', 't', env))()

local function camera_height() return presentation.at_calibrated_eye_height(V(1, 2, 0), {})[3] - root[3] end
local function near(a, b) return math.abs(a - b) < 1e-6 end

-- A human stands at the calibrated height.
assert(near(camera_height(), 1.81), 'human camera not at the calibrated height: ' .. camera_height())
-- An ogryn at its eyes: the calibrated height times its character scale.
archetype, height = 'ogryn', 0.9
local scale = presentation.calibrated_character_scale(player)
local eyes = 2.2 / 0.9125 * 0.9
assert(near(scale, eyes / 1.81), 'ogryn scale changed: ' .. scale)
assert(near(camera_height(), eyes), 'ogryn camera not at its eyes: ' .. camera_height() .. ' against ' .. eyes)
-- The game's own height changes still apply: a crouch lowers it by its fraction.
crouch = 0.6
assert(near(camera_height(), eyes * 0.6), 'ogryn crouch did not lower the camera')
-- Without a standing calibration the game's own eye point stays.
calibration = {seated = true}
assert(presentation.at_calibrated_eye_height(V(1, 2, 3), {})[3] == 3, 'an uncalibrated eye was moved')

-- Shoulders: an ogryn's joints 0.486 m out from collarbone roots 0.15 m out
-- (0.97 m wide) narrow to the player's scaled 0.49 m; a human-width avatar
-- keeps its shoulders; a target inside the roots stops at the 0.2 floor.
local function narrowing(half_root, half_joint, target)
    return presentation.shoulder_narrowing({-half_root, 0, 1.9}, {-half_joint, 0.02, 1.9},
        {half_root, 0, 1.9}, {half_joint, 0.02, 1.9}, target)
end
local factor, before, after = narrowing(0.15, 0.486, 0.49)
assert(near(before, 0.972) and near(after, 0.49), 'ogryn shoulders not narrowed to the target: ' .. tostring(after))
assert(near(factor, (0.245 - 0.15) / 0.336), 'collarbone scale wrong: ' .. tostring(factor))
assert(narrowing(0.1, 0.205, 0.41) == nil, 'a human-width avatar was narrowed')
assert(narrowing(0.1, 0.205, 0.40) == nil, 'a 2.5% difference was narrowed')
local floor = narrowing(0.15, 0.486, 0.1)
assert(floor == 0.2, 'collarbones shortened past the floor: ' .. tostring(floor))
assert(narrowing(0.15, 0.486, nil) == nil and narrowing(0.15, 0.486, 0) == nil, 'narrowed without a target')
print('character_proportions=pass human_calibrated ogryn_scaled crouch_fraction uncalibrated_native shoulders_narrowed human_width_kept collarbone_floor')
