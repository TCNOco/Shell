#Requires -Version 5.1
<#
.SYNOPSIS
    Installs a build inside the guest and registers the shell extension.

.DESCRIPTION
    Runs over PowerShell Direct in a non-interactive session, which is fine
    because none of this touches the desktop. Copies the payload into place,
    drops the test configuration, registers, and restarts Explorer so the new
    DLL is actually loaded.

    Explorer pins the DLL for as long as the extension is registered
    (DllCanUnloadNow returns S_FALSE), so replacing the file requires stopping
    Explorer first. That is the reason this restarts it rather than relying on
    a refresh.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $PayloadDir,
    [string] $InstallDir = 'C:\Program Files\TCNO Nilesoft Shell',
    [switch] $NoConfig
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Write-Host "installing from $PayloadDir to $InstallDir"

# shell.exe is linked as SubSystem=Windows. Invoking a GUI-subsystem binary with
# the call operator returns immediately without waiting and never sets
# $LASTEXITCODE, so registration would race the checks that follow it. Every
# invocation goes through Start-Process -Wait -PassThru for that reason.
function Invoke-ShellExe {
    param([string] $Path, [string[]] $Arguments, [int] $TimeoutSec = 120)

    $p = Start-Process -FilePath $Path -ArgumentList $Arguments -PassThru
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        try { $p.Kill() } catch { }
        throw "$(Split-Path $Path -Leaf) $($Arguments -join ' ') did not exit within ${TimeoutSec}s"
    }
    return $p.ExitCode
}

# Unregister and stop Explorer before touching files on disk.
$exe = Join-Path $InstallDir 'shell.exe'
if (Test-Path $exe) {
    Write-Host 'unregistering previous build'
    $rc = Invoke-ShellExe -Path $exe -Arguments @('-unregister', '-silent')
    Write-Host "  exit code $rc"
}

Write-Host 'stopping explorer'
Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2

if (Test-Path $InstallDir) {
    Remove-Item "$InstallDir\*" -Recurse -Force -ErrorAction SilentlyContinue
}
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null

Copy-Item "$PayloadDir\bin\*" $InstallDir -Recurse -Force

# Verify the binaries actually survived the copy. This DLL patches import tables
# in every process it loads into, which is exactly what antivirus heuristics
# look for, so a silent quarantine is a realistic outcome and would otherwise
# surface much later as an inexplicably empty menu. Deliberately not excluded
# from Defender up front: if it does get flagged, that is worth knowing about
# because real users will hit it too.
foreach ($required in 'shell.dll', 'shell.exe') {
    $dst = Join-Path $InstallDir $required
    $src = Join-Path "$PayloadDir\bin" $required
    if (-not (Test-Path $dst)) {
        $detected = try {
            Get-MpThreatDetection -ErrorAction Stop |
                Where-Object { $_.Resources -match [regex]::Escape($required) } |
                Select-Object -First 1
        } catch { $null }

        if ($detected) {
            throw "$required disappeared after copying; Defender flagged it as '$($detected.ThreatID)'. Add an exclusion for $InstallDir in the guest."
        }
        throw "$required is missing from $InstallDir after the copy"
    }
    $srcLen = (Get-Item $src).Length
    $dstLen = (Get-Item $dst).Length
    if ($srcLen -ne $dstLen) {
        throw "$required copied at $dstLen bytes but the payload is $srcLen bytes"
    }
}
Write-Host 'binaries verified in place'

if (-not $NoConfig) {
    Write-Host 'applying test configuration'
    Copy-Item "$PayloadDir\config\*" $InstallDir -Recurse -Force
}

# A stale log would make the smoke test's error assertion meaningless.
Remove-Item (Join-Path $InstallDir 'shell.log') -Force -ErrorAction SilentlyContinue

Write-Host 'registering'
$rc = Invoke-ShellExe -Path (Join-Path $InstallDir 'shell.exe') -Arguments @('-register', '-silent')
# Observed: -register returns 1 even on a fully successful registration, so the
# exit code is logged for information and deliberately not treated as the
# success signal. The registry check below is what actually decides.
Write-Host "  exit code $rc (not authoritative)"

# Confirm the registration landed rather than trusting the exit code.
$clsid = 'HKLM:\SOFTWARE\Classes\CLSID\{87F09619-81FA-4474-B28D-01DDBB2284F1}\InprocServer32'
if (-not (Test-Path $clsid)) {
    throw "registration did not create $clsid (shell.exe exit code $rc)"
}
$registered = (Get-ItemProperty $clsid).'(default)'
Write-Host "registered InprocServer32 -> $registered"
if ($registered -ne (Join-Path $InstallDir 'shell.dll')) {
    throw "InprocServer32 points at '$registered', expected '$(Join-Path $InstallDir 'shell.dll')'"
}

# Deliberately not Start-Process explorer.exe. This script runs over PowerShell
# Direct, which is not an interactive session, so launching Explorer from here
# would start it in the wrong session and leave the real desktop without a
# shell while adding a stray process for the smoke test to trip over. Windows
# restarts the shell by itself (Winlogon's AutoRestartShell, on by default), in
# the correct session.
Write-Host 'waiting for Windows to restart the shell'

$sw = [Diagnostics.Stopwatch]::StartNew()
$dll = Join-Path $InstallDir 'shell.dll'
while ($sw.Elapsed.TotalSeconds -lt 90) {
    Start-Sleep -Seconds 2

    # Only consider Explorer instances that own a desktop, so a shell running in
    # some other session is never mistaken for the one under test.
    $candidates = @(Get-Process explorer -ErrorAction SilentlyContinue)
    foreach ($p in $candidates) {
        try {
            if ($p.MainWindowHandle -ne 0 -or $p.SessionId -ne 0) {
                if ($p.Modules | Where-Object { $_.FileName -ieq $dll }) {
                    Write-Host "shell.dll mapped into explorer pid $($p.Id) (session $($p.SessionId)) after $([int]$sw.Elapsed.TotalSeconds)s"
                    exit 0
                }
            }
        } catch { }
    }
}

if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) {
    throw 'Windows did not restart the shell; the guest has no desktop for the smoke test to drive'
}

# Not fatal on its own: the DLL is loaded on demand by the shell, so it may not
# appear until the first menu. The smoke test asserts on it properly.
Write-Host 'warning: shell.dll not yet mapped into explorer'
exit 0
