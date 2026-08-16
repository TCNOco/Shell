#Requires -Version 5.1
<#
.SYNOPSIS
    Install a locally built Shell onto this machine, for iterating on the fork.

.DESCRIPTION
    Faster than reinstalling the MSI on every change. Explorer pins shell.dll
    for as long as the extension is registered (DllCanUnloadNow returns S_FALSE),
    so the file cannot be replaced in place - Explorer has to stop first. That is
    the whole reason this script exists rather than a copy command.

    Two things it deliberately protects you from:

    1. Upstream Nilesoft Shell registered at the same time. This fork was given
       its own CLSIDs, so both can be registered simultaneously without the
       registry complaining - and both then load into Explorer and both hook
       TrackPopupMenu. Detected and refused unless -Force.

    2. Overwriting your config. shell.nss and imports/ are left alone if they
       already exist, so a rebuild does not throw away local edits. Use
       -ResetConfig when you do want the shipped defaults back.

.PARAMETER Uninstall
    Unregister and remove the install directory, then restart Explorer.

.PARAMETER Treat
    Also write the TreatAs redirect that makes Windows 11 serve the classic
    menu. Not needed if you already have the classic menu another way, e.g. an
    empty InprocServer32 default under
    HKCU\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}.
#>
[CmdletBinding()]
param(
    [string] $InstallDir = 'C:\Program Files\TCNO Nilesoft Shell',
    [ValidateSet('x64', 'x86', 'ARM64')] [string] $Platform = 'x64',
    [switch] $Treat,
    [switch] $ResetConfig,
    [switch] $Uninstall,
    [switch] $Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# $PSScriptRoot is empty when launched through ShellExecute (Start-Process -Verb
# RunAs), which is exactly how this gets elevated.
$here = $PSScriptRoot
if (-not $here -and $MyInvocation.MyCommand.Path) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $here) { $here = (Get-Location).Path }
$repo = Resolve-Path (Join-Path $here '..')
$bin  = Join-Path $repo 'src\bin'

function Write-Step { param([string] $m) Write-Host "`n=== $m" -ForegroundColor Cyan }
function Write-Ok   { param([string] $m) Write-Host "    $m" -ForegroundColor Green }
function Write-Warn { param([string] $m) Write-Host "    $m" -ForegroundColor Yellow }

# Most InprocServer32 keys under HKLM have a default value, but not all do, and
# under Set-StrictMode a missing property is an error rather than $null. Go
# through the RegistryKey itself, where an absent value is just null.
function Get-RegDefault {
    param([string] $Path)
    $k = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if (-not $k) { return $null }
    return $k.GetValue('')
}

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
         ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) {
    throw "Run this elevated. It writes to Program Files and HKLM.`n" +
          "  Start-Process powershell -Verb RunAs -ArgumentList '-NoExit','-File','$($MyInvocation.MyCommand.Path)'"
}

# shell.exe is SubSystem=Windows, so the call operator returns immediately and
# never sets $LASTEXITCODE. Everything goes through WaitForExit.
function Invoke-ShellExe {
    param([string] $Path, [string[]] $Arguments, [int] $TimeoutSec = 120)
    $p = Start-Process -FilePath $Path -ArgumentList $Arguments -PassThru
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        try { $p.Kill() } catch { }
        throw "shell.exe $($Arguments -join ' ') did not exit within ${TimeoutSec}s"
    }
    return $p.ExitCode
}

function Restart-Explorer {
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    # Winlogon's AutoRestartShell brings it back in the right session. Only
    # start it by hand if that did not happen.
    if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) {
        Start-Process explorer.exe
        Start-Sleep -Seconds 2
    }
}

$OurClsid = '{87F09619-81FA-4474-B28D-01DDBB2284F1}'
$exe = Join-Path $InstallDir 'shell.exe'

# --- uninstall --------------------------------------------------------------
if ($Uninstall) {
    Write-Step 'Uninstall'
    if (Test-Path $exe) {
        $rc = Invoke-ShellExe -Path $exe -Arguments @('-unregister', '-treat', '-silent')
        Write-Host "    shell.exe -unregister exit $rc (not authoritative)"
    }
    Restart-Explorer
    if (Test-Path $InstallDir) { Remove-Item $InstallDir -Recurse -Force -ErrorAction SilentlyContinue }
    $left = Test-Path "HKLM:\SOFTWARE\Classes\CLSID\$OurClsid\InprocServer32"
    if ($left) { Write-Warn "registry key still present: CLSID\$OurClsid" } else { Write-Ok 'unregistered and removed' }
    return
}

# --- preflight --------------------------------------------------------------
Write-Step 'Preflight'
foreach ($f in 'shell.dll', 'shell.exe') {
    $p = Join-Path $bin $f
    if (-not (Test-Path $p)) { throw "$f not built. Run build.ps1 -Platform $Platform first ($p)" }
}

# VC-LTL changes which CRT is linked. A build without it is ~194 KB larger and
# links the CRT statically instead of importing msvcrt.dll, which is not what CI
# ships. Worth knowing before this goes into Explorer.
$dllSize = (Get-Item (Join-Path $bin 'shell.dll')).Length / 1KB
Write-Host ("    shell.dll {0:N1} KB" -f $dllSize)

# Any OTHER shell.dll registered as a context menu handler will fight this one.
$others = @()
Get-ChildItem 'HKLM:\SOFTWARE\Classes\CLSID' -ErrorAction SilentlyContinue | ForEach-Object {
    if ($_.PSChildName -eq $OurClsid) { return }
    $ip = Join-Path $_.PSPath 'InprocServer32'
    if (Test-Path $ip) {
        $v = Get-RegDefault $ip
        if ($v -and $v -match '\\shell\.dll$' -and $v -notlike "$InstallDir*") {
            $others += [pscustomobject]@{ Clsid = $_.PSChildName; Path = $v }
        }
    }
}
if ($others) {
    Write-Warn 'another Shell build is registered:'
    $others | ForEach-Object { Write-Warn "  $($_.Clsid) -> $($_.Path)" }
    Write-Warn 'Both would load into Explorer and both would hook TrackPopupMenu.'
    $otherExe = Split-Path ($others[0].Path) -Parent | Join-Path -ChildPath 'shell.exe'
    if (-not $Force) {
        throw "Unregister it first:`n" +
              "  Start-Process '$otherExe' -ArgumentList '-unregister','-silent' -Verb RunAs -Wait`n" +
              "Then re-run. Pass -Force to install anyway (not recommended)."
    }
    Write-Warn 'continuing anyway because -Force was given'
}

# --- install ----------------------------------------------------------------
Write-Step 'Install'
if (Test-Path $exe) {
    $rc = Invoke-ShellExe -Path $exe -Arguments @('-unregister', '-silent')
    Write-Host "    unregistered previous build (exit $rc)"
}

Restart-Explorer   # releases the pin on shell.dll

$keepConfig = (-not $ResetConfig) -and (Test-Path (Join-Path $InstallDir 'shell.nss'))
$stash = $null
if ($keepConfig) {
    $stash = Join-Path ([IO.Path]::GetTempPath()) ("shellcfg-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $stash | Out-Null
    Copy-Item (Join-Path $InstallDir 'shell.nss') $stash -Force
    if (Test-Path (Join-Path $InstallDir 'imports')) {
        Copy-Item (Join-Path $InstallDir 'imports') $stash -Recurse -Force
    }
    Write-Host '    existing config stashed'
}

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null

# Leftovers from a previous in-use install, once whatever held them has exited.
Get-ChildItem $InstallDir -Filter '*.old-*' -File -ErrorAction SilentlyContinue | ForEach-Object {
    Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
}

# Windows will not let a mapped image be overwritten, but it will let it be
# renamed: the mapping follows the file, so whatever is still running keeps
# working and the new binary lands in its place.
#
# This matters more than it used to. shell.dll no longer unloads while its IAT
# hooks are installed - it cannot, or the hooks dangle and the host faults - so
# every process that has ever raised a menu holds the file until it exits. That
# includes background things like Everything's service. Without this, updating
# the DLL would mean hunting processes or rebooting.
function Copy-Binary {
    param([string] $Source, [string] $Destination)

    try {
        Copy-Item $Source $Destination -Force -ErrorAction Stop
        return
    }
    catch [System.IO.IOException] {
        if (-not (Test-Path $Destination)) { throw }
    }

    $leaf  = Split-Path $Destination -Leaf
    $aside = "$leaf.old-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
    Rename-Item -LiteralPath $Destination -NewName $aside -Force -ErrorAction Stop
    Copy-Item $Source $Destination -Force -ErrorAction Stop
    Write-Warn "$leaf was in use; the old one is now $aside and is deleted on a later run"
}

Copy-Binary (Join-Path $bin 'shell.dll') (Join-Path $InstallDir 'shell.dll')
Copy-Binary (Join-Path $bin 'shell.exe') (Join-Path $InstallDir 'shell.exe')
foreach ($opt in 'shell.nss', 'imports') {
    $src = Join-Path $bin $opt
    if (Test-Path $src) { Copy-Item $src $InstallDir -Recurse -Force }
}

if ($keepConfig) {
    Copy-Item (Join-Path $stash 'shell.nss') $InstallDir -Force
    if (Test-Path (Join-Path $stash 'imports')) {
        Copy-Item (Join-Path $stash 'imports') $InstallDir -Recurse -Force
    }
    Remove-Item $stash -Recurse -Force -ErrorAction SilentlyContinue
    Write-Ok 'your config was preserved (use -ResetConfig to take the shipped defaults)'
}

# This DLL patches import tables, which is what AV heuristics look for, so a
# silent quarantine is realistic and would otherwise show up much later as an
# inexplicably empty menu.
foreach ($f in 'shell.dll', 'shell.exe') {
    $dst = Join-Path $InstallDir $f
    if (-not (Test-Path $dst)) { throw "$f vanished after copying - check Defender quarantine for $InstallDir" }
    if ((Get-Item $dst).Length -ne (Get-Item (Join-Path $bin $f)).Length) { throw "$f copied at the wrong size" }
}
Remove-Item (Join-Path $InstallDir 'shell.log') -Force -ErrorAction SilentlyContinue
Write-Ok 'files in place'

# --- register ---------------------------------------------------------------
Write-Step 'Register'
$regArgs = @('-register')
if ($Treat) { $regArgs += '-treat'; Write-Host '    with -treat (Windows 11 modern menu redirected)' }
$regArgs += '-silent'
# -register returns 1 even on success, so the registry check below decides.
$rc = Invoke-ShellExe -Path $exe -Arguments $regArgs
Write-Host "    exit $rc (not authoritative)"

$key = "HKLM:\SOFTWARE\Classes\CLSID\$OurClsid\InprocServer32"
if (-not (Test-Path $key)) { throw "registration did not create $key" }
$registered = Get-RegDefault $key
if ($registered -ne (Join-Path $InstallDir 'shell.dll')) {
    throw "InprocServer32 points at '$registered', expected '$(Join-Path $InstallDir 'shell.dll')'"
}
Write-Ok "registered -> $registered"

Restart-Explorer

Write-Step 'Done'
Write-Host '    Right-click something - the DLL loads on demand, so it will not be'
Write-Host '    mapped into Explorer until the first menu is requested.'
Write-Host ''
Write-Host "    Check it took:  (Get-Process explorer).Modules | ? FileName -match 'TCNO'"
Write-Host "    Check the log:  Get-Content '$InstallDir\shell.log' -Tail 20"
Write-Host "    Revert:         tools\install-local.ps1 -Uninstall"
