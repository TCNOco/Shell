# Compiles svgbench.c against one of the two plutosvg builds.
#
#   -Variant old   the committed prebuilt src/shared/Library/plutosvg-x64.lib
#   -Variant new   the libs built from the upgraded submodules
#
# Both produce a separate exe so before and after can be run back to back on the
# same machine without rebuilding anything in between.
#
# x64 only, deliberately. x86 would need /Gz: the prebuilt x86 lib is __stdcall
# and exports decorated names (_plutovg_create@4), which is why Shell.vcxproj
# compiles the whole DLL StdCall. On x64 there is a single calling convention
# and the question does not arise. Rasteriser throughput is not the thing that
# differs between the two architectures.
[CmdletBinding()]
param(
    [ValidateSet('old', 'new')]
    [string] $Variant = 'old',
    [string] $OutDir = (Join-Path $PSScriptRoot 'bin')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repo = Resolve-Path (Join-Path $PSScriptRoot '..\..')

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path -LiteralPath $vswhere)) { throw "vswhere not found at $vswhere" }
$vsPath = & $vswhere -latest -products * -property installationPath
if (-not $vsPath) { throw 'no Visual Studio installation found' }

$vcvars = Join-Path $vsPath 'VC\Auxiliary\Build\vcvars64.bat'
if (-not (Test-Path -LiteralPath $vcvars)) { throw "vcvars64.bat not found at $vcvars" }

New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

if ($Variant -eq 'old') {
    $includes = @(Join-Path $repo 'src\shared\Library')
    $libs     = @(Join-Path $repo 'src\shared\Library\plutosvg-x64.lib')
    $defines  = @()
} else {
    $includes = @(
        (Join-Path $repo 'src\lib\plutosvg\source')
        (Join-Path $repo 'src\lib\plutosvg\plutovg\include')
    )
    # plutosvg before plutovg: the former references the latter.
    $libs = @(
        (Join-Path $repo 'src\bin\lib\x64\plutosvg-x64.lib')
        (Join-Path $repo 'src\bin\lib\x64\plutovg-x64.lib')
    )
    # Without these the headers declare the API __declspec(dllimport), which
    # does not resolve against a static lib.
    $defines = @('/DSVGBENCH_NEW', '/DPLUTOVG_BUILD_STATIC', '/DPLUTOSVG_BUILD_STATIC')
}

foreach ($p in $includes + $libs) {
    if (-not (Test-Path -LiteralPath $p)) { throw "missing input for variant '$Variant': $p" }
}

$exe = Join-Path $OutDir "svgbench-$Variant.exe"
$obj = Join-Path $OutDir "svgbench-$Variant.obj"
$src = Join-Path $PSScriptRoot 'svgbench.c'

# /MT because both prebuilt and freshly built libs emit /DEFAULTLIB:LIBCMT.
$clArgs = @(
    '/nologo', '/O2', '/MT', '/W4', '/WX'
    $defines
    ($includes | ForEach-Object { "/I`"$_`"" })
    "/Fo`"$obj`""
    "/Fe`"$exe`""
    "`"$src`""
    '/link'
    ($libs | ForEach-Object { "`"$_`"" })
    'psapi.lib'
) | Where-Object { $_ }

$cmd = "call `"$vcvars`" >nul && cl $($clArgs -join ' ')"
Write-Host "building svgbench-$Variant.exe"
$out = & cmd.exe /c $cmd 2>&1
if ($LASTEXITCODE -ne 0) {
    $out | ForEach-Object { Write-Host $_ }
    throw "compile failed for variant '$Variant' (exit $LASTEXITCODE)"
}
$out | Where-Object { $_ -match 'error|warning' } | ForEach-Object { Write-Host $_ }

if (-not (Test-Path -LiteralPath $exe)) { throw "compile reported success but $exe is missing" }
Write-Host "  -> $exe"
