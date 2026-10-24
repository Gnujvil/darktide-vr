$ErrorActionPreference='Stop'
# Offline: the desktop testlab's light settings copy changes only the keys it
# names, inside their own blocks, and keeps encoding and line endings.
. (Join-Path $PSScriptRoot '../../tools/stereo/testlab-light-settings.ps1')
$fixture=@"
detected_user_settings = {
	master_render_settings = {
		dlss_g = 1
		graphics_quality = "high"
	}
	screen_resolution = [
		1920
		1080
	]
}
master_render_settings = {
	dlss_g = 1
	ffx_frame_gen = 0
	graphics_quality = "custom"
	rt_reflections_quality = "high"
}
mod_manager_settings = {
	developer_mode = false
}
mods_settings = {
	dmf = {
		developer_mode = false
	}
	other_mod = {
		dxr = true
		bloom_enabled = true
	}
}
render_settings = {
	ao_enabled = true
	bloom_enabled = true
	dlss_enabled = true
	dxr = true
	lod_object_multiplier = 2
	rt_reflections_enabled = true
	rtxgi_enabled = true
	sun_shadow_map_size = [
		2048
		2048
	]
	sun_shadows = true
	ui_bloom_enabled = true
	upscaling_enabled = true
	upscaling_mode = "dlss"
}
screen_resolution = [
	1920
	1080
]
texture_settings = {
	"content/texture_categories/character_bc" = 0
	"content/texture_categories/weapon_nm" = 0
}
vsync = false
"@
foreach ($newline in @("`n","`r`n")) {
    $text=$fixture -replace "`r?`n",$newline
    $light=Convert-TestlabLightSettings -Text $text -Level light
    $out=$light.Text
    $render=[regex]::Match($out,'(?ms)^render_settings = \{.*?^\}').Value
    foreach ($expect in @('dxr = false','rt_reflections_enabled = false','rtxgi_enabled = false','ao_enabled = false','lod_object_multiplier = 1')) {
        if ($render -notmatch [regex]::Escape($expect)) { throw "light: $expect missing" }
    }
    if ($render -notmatch "sun_shadow_map_size = \[$newline`t`t1024$newline`t`t1024$newline`t\]") { throw 'light: shadow map size' }
    foreach ($kept in @('bloom_enabled = true','sun_shadows = true','ui_bloom_enabled = true','dlss_enabled = true','upscaling_mode = "dlss"')) {
        if ($render -notmatch [regex]::Escape($kept)) { throw "light changed $kept" }
    }
    if ($out -notmatch '"content/texture_categories/character_bc" = 2' -or $out -notmatch '"content/texture_categories/weapon_nm" = 2') { throw 'texture mips' }
    # Other blocks and other mods' keys of the same name are untouched.
    if ($out -notmatch "other_mod = \{$newline`t`tdxr = true$newline`t`tbloom_enabled = true") { throw 'a key outside render_settings changed' }
    if (([regex]::Matches($out,'graphics_quality = "custom"')).Count -ne 1 -or $out -notmatch 'rt_reflections_quality = "high"') { throw 'master enum strings changed' }
    if ($out -notmatch "(?m)^master_render_settings = \{$newline`tdlss_g = 0") { throw 'frame generation not off' }
    if ($out -notmatch "detected_user_settings = \{$newline`tmaster_render_settings = \{$newline`t`tdlss_g = 1") { throw 'nested detected settings changed' }
    if ($out -notmatch "(?m)^`t`tdeveloper_mode = false") { throw 'developer mode changed without -DeveloperMode' }
    if ($out.Split("`n").Count -ne $text.Split("`n").Count) { throw 'line count changed' }
    if ($newline -eq "`r`n" -and ([regex]::Matches($out,"(?<!`r)`n")).Count) { throw 'line endings mixed' }
    $minimal=Convert-TestlabLightSettings -Text $text -Level minimal -NoUpscaler -DeveloperMode -Resolution 1280x720
    $mr=[regex]::Match($minimal.Text,'(?ms)^render_settings = \{.*?^\}').Value
    foreach ($expect in @('bloom_enabled = false','sun_shadows = false','dlss_enabled = false','upscaling_enabled = false','ui_bloom_enabled = true')) {
        if ($mr -notmatch [regex]::Escape($expect)) { throw "minimal: $expect" }
    }
    if ($minimal.Text -notmatch "(?m)^screen_resolution = \[$newline`t1280$newline`t720$newline\]") { throw 'resolution' }
    if ($minimal.Text -notmatch "detected_user_settings = \{(?s:.*?)1920$newline`t`t1080") { throw 'nested resolution changed' }
    if (([regex]::Matches($minimal.Text,'developer_mode = true')).Count -ne 2) { throw 'developer mode' }
    if (-not ($minimal.Changes -contains 'render_settings.dxr=false')) { throw 'change list' }
}
# Windowed edits only the top-level display keys.
$windowResult=Convert-TestlabLightSettings -Text "detected_user_settings = {`n`tfullscreen = true`n`tscreen_mode = `"fullscreen`"`n}`nfullscreen = true`nscreen_mode = `"fullscreen`"`n" -Windowed
if ($windowResult.Text -ne "detected_user_settings = {`n`tfullscreen = true`n`tscreen_mode = `"fullscreen`"`n}`nfullscreen = false`nscreen_mode = `"window`"`n") { throw 'windowed' }
# Dot-sourcing must not switch the caller into strict mode.
& { . (Join-Path $PSScriptRoot '../../tools/stereo/testlab-light-settings.ps1'); $probe=$undefinedVariable; if ($null -ne $probe) { throw 'strict' } }
# Absent keys are reported, never invented; a missing block is reported.
$sparse=Convert-TestlabLightSettings -Text "render_settings = {`n`tdxr = true`n}`n"
if ($sparse.Text -ne "render_settings = {`n`tdxr = false`n}`n" -or -not ($sparse.Changes -contains 'render_settings.rtxgi_enabled=absent') -or
    -not ($sparse.Changes -contains 'texture_settings=missing')) { throw 'sparse settings' }
# The CLI refuses to overwrite its own source.
$temp=Join-Path ([IO.Path]::GetTempPath()) "testlab-light-$PID.config"
[IO.File]::WriteAllText($temp,$fixture)
try {
    $failed=$false
    try { & (Join-Path $PSScriptRoot '../../tools/stereo/testlab-light-settings.ps1') -SourcePath $temp -DestinationPath $temp | Out-Null } catch { $failed=$true }
    if (-not $failed) { throw 'in-place conversion accepted' }
} finally { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
Write-Output 'testlab_light_settings=pass block_scoped booleans sizes textures frame_generation enums_untouched line_endings minimal resolution developer_mode windowed caller_not_strict absent_keys no_in_place'
