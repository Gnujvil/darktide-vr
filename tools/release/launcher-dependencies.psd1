# Dependencies the one-click launcher installs, pinned per release. Each is
# downloaded from its own repository at Commit (codeload.github.com zip) and
# every file is listed with its SHA-256 in the signed release manifest by
# new-launcher-release-manifest.ps1. The Mod Loader has no licence file, so
# it is fetched from upstream, never redistributed.
#
# Source: path inside the repository archive. A trailing / takes every file
# below it. Target: path below the game folder. Preserve: write only when
# missing, never remove (the player's mod list).
#
# To move a pin: update Commit, rebuild the manifest, and test a fresh
# install of the release before publishing.
@{
    ModLoader = @{
        Name = 'Darktide Mod Loader'
        Repo = 'Darktide-Mod-Framework/Darktide-Mod-Loader'
        # Release 26.06.24 (Skitarii crash fix).
        Commit = '4bd075adf47aedaabacd114a668d45789ecd9f85'
        Files = @(
            @{ Source = 'binaries/mod_loader'; Target = 'binaries/mod_loader' }
            @{ Source = 'bundle/9ba626afa44a3aa3.patch_999'; Target = 'bundle/9ba626afa44a3aa3.patch_999' }
            @{ Source = 'mods/base/'; Target = 'mods/base/' }
            @{ Source = 'mods/mod_load_order.txt'; Target = 'mods/mod_load_order.txt'; Preserve = $true }
            @{ Source = 'tools/'; Target = 'tools/' }
            @{ Source = 'toggle_darktide_mods.bat'; Target = 'toggle_darktide_mods.bat' }
        )
    }
    ModFramework = @{
        Name = 'Darktide Mod Framework'
        Repo = 'Darktide-Mod-Framework/Darktide-Mod-Framework'
        # master on 2026-10-23.
        Commit = '0107475ee51f07af2957b72fdf09b83e0b114791'
        Files = @(
            @{ Source = 'dmf/'; Target = 'mods/dmf/' }
        )
    }
}
