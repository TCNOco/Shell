#Requires -Version 5.1
<#
.SYNOPSIS
    Build Shell without a Developer Command Prompt.

.DESCRIPTION
    Neither msbuild nor nuget is on PATH in a normal shell, and this repo needs
    both kinds of restore before it will build correctly:

      - src/setup/wix is SDK-style and needs an MSBuild restore.
      - VC-LTL comes from a packages.config, which a plain `-t:Restore` skips
        unless RestorePackagesConfig is set. Skipping it does not fail the
        build: VC-LTL.props imports are conditional on the package existing, so
        the build silently links the static MSVC CRT instead of msvcrt.dll, and
        produces a binary ~194 KB larger with a different heap than the one CI
        ships. VC-LTL.props now errors out rather than letting that happen
        quietly, and this script restores so it does not come up.

    nuget.exe is never needed; MSBuild does both restores.

.PARAMETER Platform
    x64 (default), x86 or ARM64. ARM64 needs the v143 ARM64 toolset, which
    Visual Studio 18 does not ship - see the note in .github/workflows/build.yml.

.PARAMETER Rebuild
    Full rebuild instead of an incremental build.

.PARAMETER NoRestore
    Skip both restores. Only useful when iterating and you know packages are
    already in place.

.EXAMPLE
    .\build.ps1

.EXAMPLE
    .\build.ps1 -Platform x86 -Rebuild
#>
[CmdletBinding()]
param(
    [ValidateSet('x64', 'x86', 'ARM64')] [string] $Platform = 'x64',
    [ValidateSet('release', 'debug')]    [string] $Configuration = 'release',
    [switch] $Rebuild,
    [switch] $NoRestore
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repo = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$sln  = Join-Path $repo 'src\Shell.sln'
if (-not (Test-Path $sln)) { throw "solution not found: $sln" }

function Write-Step { param([string] $m) Write-Host "`n=== $m" -ForegroundColor Cyan }

# --- locate MSBuild ---------------------------------------------------------
# vswhere -latest would pick Visual Studio 18, which does not ship the v143
# ARM64 toolset that these projects target, so prefer 2022 and only fall back
# to whatever else is installed. Its -find also misses Build Tools on some
# layouts, hence the explicit probes.
function Find-MSBuild {
    $candidates = @()

    foreach ($pf in "${env:ProgramFiles}", "${env:ProgramFiles(x86)}") {
        foreach ($ed in 'Enterprise', 'Professional', 'Community', 'BuildTools') {
            $candidates += Join-Path $pf "Microsoft Visual Studio\2022\$ed\MSBuild\Current\Bin\MSBuild.exe"
        }
    }

    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path $vswhere) {
        $found = & $vswhere -products * -requires Microsoft.Component.MSBuild `
                            -find 'MSBuild\**\Bin\MSBuild.exe' 2>$null
        # amd64\MSBuild.exe exists alongside the neutral one; either works, but
        # keep it deterministic.
        $candidates += @($found | Where-Object { $_ -notmatch '\\amd64\\' })
    }

    foreach ($c in $candidates) {
        if ($c -and (Test-Path $c)) { return $c }
    }
    return $null
}

$msbuild = Find-MSBuild
if (-not $msbuild) {
    throw @'
No MSBuild found. Install "Visual Studio 2022 Build Tools" with the
"Desktop development with C++" workload (which includes the v143 toolset),
or run this from a Developer PowerShell.
'@
}
Write-Step "MSBuild"
Write-Host "    $msbuild"

$common = @(
    "-p:Configuration=$Configuration"
    "-p:Platform=$Platform"
    '-nologo'
)

if (-not $NoRestore) {
    Write-Step "Restore ($Platform)"
    # RestorePackagesConfig is the part that matters: without it VC-LTL is not
    # restored and the resulting binary differs from CI's.
    & $msbuild $sln -t:Restore -p:RestorePackagesConfig=true @common -v:minimal
    if ($LASTEXITCODE -ne 0) { throw "restore failed with exit code $LASTEXITCODE" }

    $ltl = Join-Path $repo 'src\packages\VC-LTL.5.1.1\build\native'
    if (Test-Path $ltl) { Write-Host "    VC-LTL present" -ForegroundColor Green }
    else { Write-Host "    VC-LTL missing - the build will stop and tell you why" -ForegroundColor Yellow }
}

Write-Step "Build ($Configuration|$Platform)"
$target = if ($Rebuild) { '-t:Rebuild' } else { '-t:Build' }
& $msbuild $sln $target -m @common -v:minimal
if ($LASTEXITCODE -ne 0) { throw "build failed with exit code $LASTEXITCODE" }

# --- report -----------------------------------------------------------------
# The test suite runs as a post-build step of the tests project on x64, so
# reaching here on x64 means it passed.
Write-Step "Output"
$bin = Join-Path $repo 'src\bin'
Get-ChildItem $bin -File |
    Where-Object { $_.Extension -in '.msi', '.dll', '.exe' -and $_.Name -ne 'tests.exe' } |
    Sort-Object Name |
    ForEach-Object { Write-Host ("    {0,-18} {1,9:N1} KB" -f $_.Name, ($_.Length / 1KB)) }

Write-Host "`nInstall with:  tools\install-local.ps1" -ForegroundColor Cyan
