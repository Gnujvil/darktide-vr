local module = dofile(arg[1])
local hooks, settings, render = {}, {render_settings={rt_reflections_enabled=false,rtxgi_enabled=true}}, {}
local raytrace_log
local ui = {update=function() return 'updated' end}
require = function() return ui end
local applied
ShadingEnvironment = {
    set_scalar = function(environment, key, value) environment[key] = value end,
    apply = function(environment, marker)
        -- Inspect at the original function boundary, not after application.
        assert(environment.dof_enabled == 0 and environment.fullscreen_blur_enabled == 0)
        assert(environment.fullscreen_blur_amount == 0)
        applied = environment
        return marker, nil, 'applied_environment'
    end,
}
Application = {
    user_setting = function(location, key) return settings[location][key] end,
    set_user_setting = function(location, key, value)
        if value == nil and type(key) ~= 'table' then
            settings[location] = key
            return
        end
        settings[location] = settings[location] or {}
        if type(key) == 'table' then settings[location] = key
        else settings[location][key] = value end
    end,
    set_render_setting = function(key, value) render[key] = value end,
    apply_user_settings = function() return 'applied' end,
}
mod = {
    hook = function(self, target, name, fn)
        local original = target[name]
        hooks[target] = hooks[target] or {}
        assert(not hooks[target][name], 'DMF rejects duplicate hooks from one mod')
        hooks[target][name] = true
        target[name] = function(...) return fn(original, ...) end
    end,
    hook_safe = function() error('Register startup through the existing UI update hook') end,
    info = function(_, format, ...)
        if format:find('DARKTIDEVR_RAYTRACE', 1, true) then raytrace_log=string.format(format, ...) end
    end,
}
module.install(mod)
if arg[2] then
    local file = assert(io.open(arg[2], 'r'))
    local source = file:read('*all')
    file:close()
    local first = assert(source:find('mod:hook(\n    require("scripts/managers/ui/ui_manager"),\n    "update",', 1, true))
    local last = assert(source:find('\n-- Darktide', first, true))
    local noop = function() end
    presentation = {
        visual_settings=module, begin_menu_pointer_frame=noop,
        reconcile_fullscreen_views=noop, update_system_menu_test=noop,
        update_vendor_menu_test=noop, update_psykhanium=noop,
        update_dlss_quality_test=noop,
    }
    assert(loadstring(source:sub(first,last-1)))()
    assert(ui.update({}, .01, 1) == 'updated')
else
    module.update()
end
assert(raytrace_log == 'DARKTIDEVR_RAYTRACE user_reflections=false user_rtxgi=true',
    'read actual user settings and preserve false separately from unavailable')
assert(render.dof_enabled == 'false')
assert(settings.fullscreen == false and settings.borderless_fullscreen == false)
assert(settings.screen_mode == 'window')
Application.set_user_setting('fullscreen', true)
Application.set_user_setting('screen_mode', 'fullscreen')
assert(settings.fullscreen == false and settings.screen_mode == 'window')
local preset = { dof_enabled = true, motion_blur_enabled = true, unrelated = 7 }
Application.set_user_setting('render_settings', preset)
assert(preset.dof_enabled == true, 'do not mutate the shared preset')
assert(settings.render_settings.dof_enabled == false)
assert(settings.render_settings.unrelated == 7)
Application.set_user_setting('master_render_settings', 'dof_quality', 'high')
assert(settings.master_render_settings.dof_quality == 'off')
Application.set_render_setting('sun_flare_enabled', 'true')
assert(render.sun_flare_enabled == 'false')
Application.set_render_setting('unrelated', 'true')
assert(render.unrelated == 'true')
settings.render_settings.lens_quality_enabled = true
assert(Application.apply_user_settings() == 'applied')
assert(settings.render_settings.lens_quality_enabled == false)
local scene = {dof_enabled=1, fullscreen_blur_enabled=1, fullscreen_blur_amount=.8,
    exposure_compensation=2, ui_bloom_enabled=1, grey_scale_enabled=1}
local marker, middle, last = ShadingEnvironment.apply(scene, 'scene')
assert(marker == 'scene' and middle == nil and last == 'applied_environment')
assert(applied == scene and scene.exposure_compensation == 2 and scene.ui_bloom_enabled == 1)
assert(scene.grey_scale_enabled == 1, 'unrelated environment effect was changed')
-- Simulate a subsequent mood blend replacing scalar values without going
-- through set_render_setting, followed by a camera's direct DOF write.
scene.fullscreen_blur_enabled, scene.fullscreen_blur_amount = 1, .5
ShadingEnvironment.set_scalar(scene, 'dof_enabled', 1)
ShadingEnvironment.apply(scene)
local second_scene = {dof_enabled=1, exposure_compensation=-1}
ShadingEnvironment.apply(second_scene)
assert(second_scene.exposure_compensation == -1, 'second viewport lighting changed')

-- Frame generation: a fresh module instance per case, against the player's
-- saved choice of DLSS Frame Generation on.
local function frame_generation_case(native, ready_after)
    local instance = dofile(arg[1])
    local user = {render_settings={dlss_g_enabled=true, dlss_g_frames_to_generate=1},
        master_render_settings={dlss_g=1}}
    local engine, decision, updates = {}, nil, 0
    ShadingEnvironment = {set_scalar=function() end, apply=function() end}
    Application = {
        user_setting = function(location, key) return user[location][key] end,
        set_user_setting = function(location, key, value)
            if type(key) == 'table' then user[location] = key
            elseif value ~= nil then
                user[location] = user[location] or {}
                user[location][key] = value
            else user[location] = key end
        end,
        set_render_setting = function(key, value) engine[key] = value end,
        apply_user_settings = function() end,
    }
    local frame_mod = {
        hook = function(_, target, name, fn)
            local original = target[name]
            target[name] = function(...) return fn(original, ...) end
        end,
        info = function(_, format, ...)
            if format:find('DARKTIDEVR_FRAME_GENERATION', 1, true) then
                assert(not decision, 'decided more than once')
                decision = string.format(format, ...)
            end
        end,
    }
    instance.install(frame_mod, function()
        if updates < (ready_after or 0) then return nil end
        return native, function(library, name) return library[name] ~= nil end
    end)
    for _ = 1, (ready_after or 0) + 1 do
        instance.update()
        updates = updates + 1
    end
    return user, engine, decision
end

local unavailable = {dtvr_bootstrap_state=function() return 1 end,
    dtvr_generated_stereo_state=function() return 0 end}
local user, engine, decision = frame_generation_case(unavailable)
assert(decision == 'DARKTIDEVR_FRAME_GENERATION generated_stereo=false user_dlss_g=true policy=forced_off',
    tostring(decision))
assert(user.render_settings.dlss_g_enabled == false and engine.dlss_g_enabled == 'false',
    'generation the headset cannot receive must not run (Bimo, 25 October)')
assert(user.master_render_settings.dlss_g == 0, 'the options menu must show it off')
assert(user.render_settings.dlss_g_frames_to_generate == 1, 'unrelated setting changed')
Application.set_user_setting('render_settings', 'dlss_g_enabled', true)
Application.set_user_setting('master_render_settings', 'dlss_g', 1)
Application.set_render_setting('dlss_g_enabled', 'true')
assert(user.render_settings.dlss_g_enabled == false and user.master_render_settings.dlss_g == 0)
assert(engine.dlss_g_enabled == 'false', 'a menu toggle re-enabled frame generation')
local fg_preset = {dlss_g_enabled=true, upscaling_quality='balanced'}
Application.set_user_setting('render_settings', fg_preset)
assert(fg_preset.dlss_g_enabled == true, 'do not mutate the shared preset')
assert(user.render_settings.dlss_g_enabled == false and user.render_settings.dof_enabled == false)
assert(user.render_settings.upscaling_quality == 'balanced', 'graphics quality changed')
Application.set_user_setting('master_render_settings', 'texture_quality', 'high')
assert(user.master_render_settings.texture_quality == 'high', 'graphics quality changed')

user, engine, decision = frame_generation_case({dtvr_bootstrap_state=function() return 1 end,
    dtvr_generated_stereo_state=function() return 1 end})
assert(decision == 'DARKTIDEVR_FRAME_GENERATION generated_stereo=true user_dlss_g=true policy=user', tostring(decision))
assert(user.render_settings.dlss_g_enabled == true and engine.dlss_g_enabled == nil)
Application.set_user_setting('master_render_settings', 'dlss_g', 1)
assert(user.master_render_settings.dlss_g == 1, 'a working headset path keeps the choice')

user, engine, decision = frame_generation_case({dtvr_bootstrap_state=function() return 0 end,
    dtvr_generated_stereo_state=function() return 0 end})
assert(decision:find('policy=user', 1, true) and user.render_settings.dlss_g_enabled == true,
    'flat play keeps its frame generation')

user, engine, decision = frame_generation_case({dtvr_bootstrap_state=function() return 1 end})
assert(decision == 'DARKTIDEVR_FRAME_GENERATION generated_stereo=unknown user_dlss_g=true policy=user', tostring(decision))
assert(user.render_settings.dlss_g_enabled == true, 'an older module without the export is unchanged')

user, engine, decision = frame_generation_case(unavailable, 2)
assert(decision and decision:find('policy=forced_off', 1, true), 'a late native module still decides')
assert(user.render_settings.dlss_g_enabled == false and engine.dlss_g_enabled == 'false')
print('VR visual settings: startup, presets, direct writes, apply, environment bypasses and frame generation passed')
