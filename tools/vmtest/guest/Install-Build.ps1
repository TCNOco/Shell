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

# Unregister and stop Explorer before touching files on disk.
$exe = Join-Path $InstallDir 'shell.exe'
if (Test-Path $exe) {
    Write-Host 'unregistering previous build'
    & $exe -unregister -silent
    Start-Sleep -Seconds 1
}

Write-Host 'stopping explorer'
Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2

if (Test-Path $InstallDir) {
    Remove-Item "$InstallDir\*" -Recurse -Force -ErrorAction SilentlyContinue
}
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null

Copy-Item "$PayloadDir\bin\*" $InstallDir -Recurse -Force

if (-not $NoConfig) {
    Write-Host 'applying test configuration'
    Copy-Item "$PayloadDir\config\*" $InstallDir -Recurse -Force
}

# A stale log would make the smoke test's error assertion meaningless.
Remove-Item (Join-Path $InstallDir 'shell.log') -Force -ErrorAction SilentlyContinue

Write-Host 'registering'
& (Join-Path $InstallDir 'shell.exe') -register -silent
$rc = $LASTEXITCODE

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

Write-Host 'starting explorer'
Start-Process explorer.exe

# Wait for the shell to come back and map the DLL, rather than sleeping blind.
$sw = [Diagnostics.Stopwatch]::StartNew()
$dll = Join-Path $InstallDir 'shell.dll'
while ($sw.Elapsed.TotalSeconds -lt 60) {
    Start-Sleep -Seconds 2
    $p = Get-Process explorer -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($p) {
        try {
            if ($p.Modules | Where-Object { $_.FileName -ieq $dll }) {
                Write-Host "shell.dll mapped into explorer pid $($p.Id) after $([int]$sw.Elapsed.TotalSeconds)s"
                exit 0
            }
        } catch { }
    }
}

# Not fatal on its own: the DLL is loaded on demand by the shell, so it may not
# appear until the first menu. The smoke test asserts on it properly.
Write-Host 'warning: shell.dll not yet mapped into explorer'
exit 0
