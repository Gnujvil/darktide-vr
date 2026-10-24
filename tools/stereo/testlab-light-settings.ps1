[CmdletBinding()]
param(
    # A Darktide user_settings.config to read (never modified).
    [string] $SourcePath,
    # Where the light copy goes (a session's own settings file).
    [string] $DestinationPath,
    # light: no ray tracing, no AO/volumetrics/light shafts/local-light shadows,
    # small shadow maps, quarter-resolution textures, frame generation off.
    # minimal: light, plus bloom, sharpening, skin shading and sun shadows off.
    [ValidateSet('light','minimal')][string] $Level='light',
    # WIDTHxHEIGHT, or keep. The VR launcher path forces 1920x1080 itself.
    [string] $Resolution='keep',
    # Also turn DLSS/upscaling off (booleans only; the upscaler mode string stays).
    [switch] $NoUpscaler,
    # DMF developer mode on: required for an in-place mod reload (testlab reload verb).
    [switch] $DeveloperMode,
    # Top-level screen_mode "window" and fullscreen false (direct launches).
    [switch] $Windowed
)
# Desktop testlab sessions only: produces a lighter copy of a settings file.
# Only engine render_settings booleans/sizes and the numeric texture mip
# levels change; master_render_settings enum strings (the options menu's
# view of them) are left as they are, so no guessed enum value is written.
# Dot-source to use Convert-TestlabLightSettings without running the CLI
# (strict mode stays inside these functions, not the caller's scope).

function Set-BlockValues([string] $Text,[string] $Block,[hashtable] $Values,[Collections.Generic.List[string]] $Changes,[string] $Prefix) {
    Set-StrictMode -Version Latest
    # A top-level "<Block> = {" ... "}" section; only keys inside it change.
    $match=[regex]::Match($Text,"(?ms)^$([regex]::Escape($Block)) = \{\r?\n(?<body>.*?)^\}")
    if (-not $match.Success) { $Changes.Add("$Prefix$Block=missing");return $Text }
    $body=$match.Groups['body'].Value
    foreach ($key in @($Values.Keys | Sort-Object)) {
        $value=$Values[$key]
        $quoted=[regex]::Escape($key)
        if ($value -is [array]) {
            $pattern="(?ms)^(?<indent>[\t ]+)$quoted = \[\r?\n.*?^\k<indent>\]"
            $m=[regex]::Match($body,$pattern)
            if (-not $m.Success) { $Changes.Add("$Prefix$key=absent");continue }
            $newline=if ($m.Value -match "`r`n") {"`r`n"} else {"`n"}
            $indent=$m.Groups['indent'].Value
            $replacement="$indent$key = [$newline"+(($value | ForEach-Object {"$indent`t$_$newline"}) -join '')+"$indent]"
            if ($m.Value -ne $replacement) { $Changes.Add("$Prefix$key=[$($value -join ' ')]") }
            $body=$body.Substring(0,$m.Index)+$replacement+$body.Substring($m.Index+$m.Length)
        } else {
            $literal=if ($value -is [bool]) {$value.ToString().ToLowerInvariant()} else {[string]$value}
            $pattern="(?m)^(?<indent>[\t ]+)$quoted = (?<old>[^\r\n]*)"
            $m=[regex]::Match($body,$pattern)
            if (-not $m.Success) { $Changes.Add("$Prefix$key=absent");continue }
            if ($m.Groups['old'].Value -ne $literal) { $Changes.Add("$Prefix$key=$literal") }
            $body=$body.Substring(0,$m.Groups['old'].Index)+$literal+$body.Substring($m.Groups['old'].Index+$m.Groups['old'].Length)
        }
    }
    $start=$match.Groups['body'].Index
    return $Text.Substring(0,$start)+$body+$Text.Substring($start+$match.Groups['body'].Length)
}

function Convert-TestlabLightSettings {
    param([Parameter(Mandatory)][string] $Text,[string] $Level='light',[string] $Resolution='keep',
        [switch] $NoUpscaler,[switch] $DeveloperMode,[switch] $Windowed)
    Set-StrictMode -Version Latest
    $changes=[Collections.Generic.List[string]]::new()
    $render=@{dxr=$false;rt_reflections_enabled=$false;rt_checkerboard_reflections=$false;rtxgi_enabled=$false;
        ao_enabled=$false;gtao_enabled=$false;cacao_enabled=$false;light_shafts_enabled=$false;
        volumetric_volumes_enabled=$false;volumetric_lighting_local_lights=$false;volumetric_extrapolation_high_quality=$false;
        local_lights_shadows_enabled=$false;motion_blur_enabled=$false;dof_enabled=$false;dof_high_quality=$false;
        ssr_enabled=$false;ssr_high_quality=$false;lens_flares_enabled=$false;sun_flare_enabled=$false;
        dlss_g_enabled=$false;ffx_frame_gen_enabled=$false;fsr_rr_enabled=$false;reflex_warp_enabled=$false;
        lod_object_multiplier=1;
        sun_shadow_map_size=@(1024,1024);static_sun_shadow_map_size=@(1024,1024);local_lights_shadow_atlas_size=@(512,512)}
    if ($Level -eq 'minimal') {
        $render.bloom_enabled=$false;$render.sharpen_enabled=$false;$render.skin_material_enabled=$false
        $render.sun_shadows=$false;$render.static_sun_shadows=$false;$render.display_noise_enabled=$false
        $render.sun_shadow_map_size=@(512,512);$render.static_sun_shadow_map_size=@(512,512)
    }
    if ($NoUpscaler) { $render.dlss_enabled=$false;$render.upscaling_enabled=$false }
    $Text=Set-BlockValues $Text 'render_settings' $render $changes 'render_settings.'
    # Numeric mip levels dropped per texture category (0 = full resolution).
    $textures=@{}
    foreach ($m in [regex]::Matches($Text,'(?m)^[\t ]+("content/texture_categories/[^"]+") = ')) { $textures[$m.Groups[1].Value]=2 }
    if ($textures.Count) { $Text=Set-BlockValues $Text 'texture_settings' $textures $changes 'texture_settings.' }
    else { $changes.Add('texture_settings=missing') }
    $Text=Set-BlockValues $Text 'master_render_settings' @{dlss_g=0;ffx_frame_gen=0} $changes 'master_render_settings.'
    if ($Resolution -ne 'keep') {
        if ($Resolution -notmatch '^(\d{3,4})x(\d{3,4})$') { throw 'Resolution must be WIDTHxHEIGHT or keep' }
        $size=@([int]$Matches[1],[int]$Matches[2])
        $pattern='(?ms)^(?<name>screen_resolution) = \[\r?\n.*?^\]'
        $m=[regex]::Match($Text,$pattern)
        if (-not $m.Success) { $changes.Add('screen_resolution=missing') }
        else {
            $newline=if ($m.Value -match "`r`n") {"`r`n"} else {"`n"}
            $Text=$Text.Substring(0,$m.Index)+"screen_resolution = [$newline`t$($size[0])$newline`t$($size[1])$newline]"+$Text.Substring($m.Index+$m.Length)
            $changes.Add("screen_resolution=[$($size -join ' ')]")
        }
    }
    if ($Windowed) {
        foreach ($pair in @(@('screen_mode','"window"'),@('fullscreen','false'))) {
            $m=[regex]::Match($Text,"(?m)^$($pair[0]) = (?<old>[^
]*)")
            if (-not $m.Success) { $changes.Add("$($pair[0])=missing");continue }
            if ($m.Groups['old'].Value -ne $pair[1]) { $changes.Add("$($pair[0])=$($pair[1])") }
            $Text=$Text.Substring(0,$m.Groups['old'].Index)+$pair[1]+$Text.Substring($m.Groups['old'].Index+$m.Groups['old'].Length)
        }
    }
    if ($DeveloperMode) {
        $count=[regex]::Matches($Text,'(?m)^([\t ]*developer_mode = )false').Count
        $Text=[regex]::Replace($Text,'(?m)^([\t ]*developer_mode = )false','${1}true')
        if ($count) { $changes.Add("developer_mode=true x$count") }
    }
    [pscustomobject]@{Text=$Text;Changes=$changes.ToArray()}
}

if ($MyInvocation.InvocationName -ne '.') {
    Set-StrictMode -Version Latest
    $ErrorActionPreference='Stop'
    if (-not $SourcePath -or -not $DestinationPath) { throw 'SourcePath and DestinationPath are required' }
    $source=[IO.Path]::GetFullPath($SourcePath);$destination=[IO.Path]::GetFullPath($DestinationPath)
    if ($source -ieq $destination) { throw 'Write the light copy to a different file than its source' }
    $bytes=[IO.File]::ReadAllBytes($source)
    $bom=$bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $text=[Text.UTF8Encoding]::new($false).GetString($bytes,$(if ($bom) {3} else {0}),$bytes.Length-$(if ($bom) {3} else {0}))
    $result=Convert-TestlabLightSettings -Text $text -Level $Level -Resolution $Resolution -NoUpscaler:$NoUpscaler -DeveloperMode:$DeveloperMode -Windowed:$Windowed
    [IO.File]::WriteAllText($destination,$result.Text,[Text.UTF8Encoding]::new($bom))
    Write-Output "testlab_light_settings level=$Level changes=$($result.Changes.Count) destination=$destination"
    $result.Changes | ForEach-Object { Write-Output "  $_" }
}
