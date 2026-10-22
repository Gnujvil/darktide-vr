[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$build=Join-Path $repo 'build/melee-inertia'
$vswhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
$vs=& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vs) { throw 'Visual Studio x64 C++ tools are required' }
$vcvars=Join-Path $vs 'VC/Auxiliary/Build/vcvars64.bat'
New-Item -ItemType Directory -Path $build -Force | Out-Null
$batch=Join-Path $build 'build.cmd'
@"
@echo off
call "$vcvars"
if errorlevel 1 exit /b 1
cd /d "$build"
cl /nologo /std:c++20 /EHsc /W4 /O2 /LD /DDTVR_MELEE_BUILD "$repo/src/melee_inertia/melee_inertia.cpp" "$repo/src/melee_inertia/vendor/heft/heft.cpp" /Fe:darktidevr_melee_inertia.dll
if errorlevel 1 exit /b 1
cl /nologo /std:c++20 /EHsc /W4 /O2 "$repo/tests/melee_inertia/test.cpp" darktidevr_melee_inertia.lib /Fe:melee-inertia-tests.exe
if errorlevel 1 exit /b 1
melee-inertia-tests.exe
"@ | Set-Content -LiteralPath $batch -Encoding ascii
& $env:ComSpec /d /c $batch
if ($LASTEXITCODE) { throw 'Melee inertia build or numerical acceptance failed' }
Copy-Item -LiteralPath (Join-Path $repo 'src/melee_inertia/vendor/heft/LICENSE') -Destination (Join-Path $build 'HEFT-LICENSE.txt') -Force
$sources=[ordered]@{}
foreach($relative in @('src/melee_inertia/melee_inertia.cpp','src/melee_inertia/melee_inertia.h',
    'src/melee_inertia/vendor/heft/heft.cpp','src/melee_inertia/vendor/heft/heft.h')) {
    $sources[$relative]=(Get-FileHash -LiteralPath (Join-Path $repo $relative)).Hash
}
[ordered]@{abi=4;sources=$sources;library_hash=(Get-FileHash -LiteralPath (Join-Path $build 'darktidevr_melee_inertia.dll')).Hash} |
    ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $build 'build.json')
Write-Output "melee_inertia_build=pass dll=$(Join-Path $build 'darktidevr_melee_inertia.dll')"
