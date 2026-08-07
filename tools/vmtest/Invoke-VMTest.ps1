#Requires -Version 5.1
<#
.SYNOPSIS
    Build, deploy into a Hyper-V VM, open a real context menu, assert, revert.

.DESCRIPTION
    The shell extension is a DLL injected into explorer.exe. A bad build means a
    black desktop, and Explorer pins the DLL for as long as it is registered, so
    iterating on the host means killing the shell on every change. This runs the
    whole cycle against a throwaway VM instead, from a known-good checkpoint
    every time.

    Transport is PowerShell Direct, so the VM needs no network and no shared
    folder. The smoke test itself cannot run over PowerShell Direct because that
    session is not interactive and cannot see the desktop, so it is registered
    as a scheduled task running as the logged-on user and its result is read
    back from a file.

.PARAMETER VMName
    Hyper-V VM to test in. Must have a checkpoint named by -Checkpoint.

.PARAMETER Checkpoint
    Known-good checkpoint restored before each run. Create it once with the
    guest logged in and auto-logon enabled; see README.md.

.EXAMPLE
    .\Invoke-VMTest.ps1 -VMName shell-test

.EXAMPLE
    .\Invoke-VMTest.ps1 -VMName shell-test -SkipBuild -KeepRunning
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $VMName,
    [string] $Checkpoint = 'clean',
    [ValidateSet('x64', 'x86', 'arm64')] [string] $Platform = 'x64',
    [string] $Configuration = 'release',
    # Bare account name. Used for the scheduled task principal and nothing else.
    [string] $GuestUser = 'tester',
    # Name used to authenticate. PowerShell Direct frequently needs the
    # qualified 'PCNAME\user' form where the bare name is rejected outright,
    # so this is kept separate from $GuestUser rather than derived from it.
    [string] $GuestLogon,
    [pscredential] $Credential,
    [string] $InstallDir = 'C:\Program Files\TCNO Nilesoft Shell',
    [string] $ArtifactDir,
    [switch] $SkipBuild,
    [switch] $SkipConfig,
    [switch] $KeepRunning,
    [int] $BootTimeoutSec = 300
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# $PSScriptRoot comes back empty when a script is launched through ShellExecute
# (Start-Process -Verb RunAs), so resolve the directory defensively.
$vmtest = $PSScriptRoot
if (-not $vmtest -and $MyInvocation.MyCommand.Path) {
    $vmtest = Split-Path -Parent $MyInvocation.MyCommand.Path
}
if (-not $vmtest) { $vmtest = (Get-Location).Path }
$repo = Resolve-Path (Join-Path $vmtest '..\..')
if (-not $ArtifactDir) {
    $ArtifactDir = Join-Path $vmtest ('runs\{0:yyyyMMdd-HHmmss}' -f (Get-Date))
}

function Write-Step { param([string] $m) Write-Host "`n=== $m" -ForegroundColor Cyan }
function Write-Ok   { param([string] $m) Write-Host "    $m" -ForegroundColor Green }
function Write-Bad  { param([string] $m) Write-Host "    $m" -ForegroundColor Red }

# ------------------------------------------------------------------- build

if (-not $SkipBuild) {
    Write-Step "Build $Configuration|$Platform"

    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vswhere)) { throw "vswhere not found at $vswhere" }

    $msbuild = & $vswhere -latest -requires Microsoft.Component.MSBuild `
                          -find 'MSBuild\**\Bin\MSBuild.exe' | Select-Object -First 1
    if (-not $msbuild) {
        # vswhere -find misses Build Tools installs on some layouts.
        $msbuild = Get-ChildItem "${env:ProgramFiles}\Microsoft Visual Studio" -Recurse -Filter MSBuild.exe -ErrorAction SilentlyContinue |
                   Where-Object { $_.FullName -match '\\Current\\Bin\\MSBuild\.exe$' -and $_.FullName -notmatch 'amd64' } |
                   Select-Object -First 1 -ExpandProperty FullName
    }
    if (-not $msbuild) { throw 'no MSBuild found' }

    & $msbuild (Join-Path $repo 'src\Shell.sln') /m `
        /p:Configuration=$Configuration /p:Platform=$Platform /v:minimal /nologo
    if ($LASTEXITCODE -ne 0) { throw "build failed with exit code $LASTEXITCODE" }
    Write-Ok 'build succeeded'
}

$bin = Join-Path $repo 'src\bin'
foreach ($required in 'shell.dll', 'shell.exe') {
    if (-not (Test-Path (Join-Path $bin $required))) { throw "missing build output: $required" }
}

# -------------------------------------------------------------- stage payload

Write-Step 'Stage payload'
$payload = Join-Path $ArtifactDir 'payload'
New-Item -ItemType Directory -Force -Path (Join-Path $payload 'bin') | Out-Null

Copy-Item (Join-Path $bin 'shell.dll') (Join-Path $payload 'bin') -Force
Copy-Item (Join-Path $bin 'shell.exe') (Join-Path $payload 'bin') -Force
foreach ($pdb in 'shell.dll.pdb', 'shell.exe.pdb') {
    $p = Join-Path $bin $pdb
    if (Test-Path $p) { Copy-Item $p (Join-Path $payload 'bin') -Force }
}
if (Test-Path (Join-Path $bin 'imports')) {
    Copy-Item (Join-Path $bin 'imports') (Join-Path $payload 'bin') -Recurse -Force
}
Copy-Item (Join-Path $vmtest 'config') $payload -Recurse -Force
Write-Ok "staged $((Get-ChildItem $payload -Recurse -File).Count) file(s)"

# ------------------------------------------------------------------- vm

Write-Step "Restore '$Checkpoint' on $VMName"

# Deliberately not '#Requires -RunAsAdministrator': membership of the local
# Hyper-V Administrators group is enough, and requiring elevation would lock
# those users out for no reason. Check the capability rather than the token.
try { $null = Get-VM -ErrorAction Stop }
catch {
    throw @"
Cannot query Hyper-V: $($_.Exception.Message)

Either run this from an elevated PowerShell, or grant your account standing
access and sign out once:

    Add-LocalGroupMember -Group 'Hyper-V Administrators' -Member '$env:USERNAME'
"@
}

$vm = Get-VM -Name $VMName -ErrorAction Stop
if (-not (Get-VMCheckpoint -VMName $VMName -Name $Checkpoint -ErrorAction SilentlyContinue)) {
    throw "VM '$VMName' has no checkpoint named '$Checkpoint'. See tools/vmtest/README.md."
}
if ($vm.State -ne 'Off') { Stop-VM -Name $VMName -TurnOff -Force }
Restore-VMCheckpoint -VMName $VMName -Name $Checkpoint -Confirm:$false
Write-Ok 'checkpoint restored'

Write-Step 'Start and wait for guest'
Start-VM -Name $VMName -ErrorAction SilentlyContinue | Out-Null

# PowerShell Direct authenticates against an account inside the guest, so the
# username must not be prefixed with the VM name -- the VM name is a host-side
# label and has nothing to do with the guest's computer name.
if (-not $Credential) {
    if (-not $GuestLogon) { $GuestLogon = $GuestUser }
    $Credential = Get-Credential -UserName $GuestLogon `
        -Message "Account inside '$VMName'. Use the qualified PCNAME\user form if the bare name is rejected."
}
$cred = $Credential

$sw = [Diagnostics.Stopwatch]::StartNew()
$session = $null
while ($sw.Elapsed.TotalSeconds -lt $BootTimeoutSec) {
    try {
        $session = New-PSSession -VMName $VMName -Credential $cred -ErrorAction Stop
        break
    }
    catch { Start-Sleep -Seconds 5 }
}
if (-not $session) { throw "guest did not accept PowerShell Direct within ${BootTimeoutSec}s" }
Write-Ok "guest ready after $([int]$sw.Elapsed.TotalSeconds)s"

$exitCode = 1
try {
    # ------------------------------------------------------------- deploy

    Write-Step 'Copy payload into guest'
    Invoke-Command -Session $session -ScriptBlock {
        if (Test-Path 'C:\vmtest') { Remove-Item 'C:\vmtest' -Recurse -Force }
        New-Item -ItemType Directory -Force -Path 'C:\vmtest' | Out-Null
    }
    Copy-Item -Path $payload -Destination 'C:\vmtest\payload' -ToSession $session -Recurse -Force
    Copy-Item -Path (Join-Path $vmtest 'guest\Install-Build.ps1')    -Destination 'C:\vmtest\' -ToSession $session -Force
    Copy-Item -Path (Join-Path $vmtest 'guest\Invoke-SmokeTest.ps1') -Destination 'C:\vmtest\' -ToSession $session -Force
    Write-Ok 'copied'

    Write-Step 'Install and register'
    $install = Invoke-Command -Session $session -ScriptBlock {
        param($installDir, $skipConfig)
        # Build the argument list explicitly. An inline @(if (...) { '-NoConfig' })
        # in argument position stringifies unpredictably, including passing an
        # empty argument when the condition is false.
        $a = @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass',
            '-File', 'C:\vmtest\Install-Build.ps1',
            '-PayloadDir', 'C:\vmtest\payload',
            '-InstallDir', $installDir
        )
        if ($skipConfig) { $a += '-NoConfig' }

        $output = & powershell.exe @a 2>&1
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
    } -ArgumentList $InstallDir, [bool]$SkipConfig

    $install.Output | ForEach-Object { Write-Host "    $_" }

    # The exit code used to be collected and then ignored, so a failed install
    # fell through to the smoke test and reported itself as a pile of missing
    # menu items rather than as an install failure.
    if ($install.ExitCode -ne 0) {
        throw "install failed in the guest with exit code $($install.ExitCode); see output above"
    }
    Write-Ok 'installed and registered'

    # ---------------------------------------------------- interactive test

    # PowerShell Direct sessions are not interactive and cannot see the desktop,
    # so the smoke test runs as a scheduled task in the logged-on user's session.
    Write-Step 'Run smoke test in the interactive session'
    $taskReport = Invoke-Command -Session $session -ScriptBlock {
        param($installDir, $user)

        $out = [ordered]@{}

        # An Interactive-logon task only runs if that user actually has a
        # session. Without this check a missing session looks identical to a
        # smoke test that ran and produced nothing.
        $sessions = @(Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction SilentlyContinue |
                      ForEach-Object { (Invoke-CimMethod -InputObject $_ -MethodName GetOwner).User } |
                      Where-Object { $_ })
        $out.interactiveUsers = ($sessions | Sort-Object -Unique) -join ','
        if (-not $sessions) {
            $out.error = 'no interactive session in the guest; auto-logon is not working'
            return $out
        }

        $taskName = 'TCNOShellSmokeTest'
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        Remove-Item 'C:\vmtest\result.json', 'C:\vmtest\menu.png' -Force -ErrorAction SilentlyContinue

        $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
            -Argument ("-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden " +
                       "-File C:\vmtest\Invoke-SmokeTest.ps1 -InstallDir `"$installDir`"")
        $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
        Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal | Out-Null
        Start-ScheduledTask -TaskName $taskName

        $sw = [Diagnostics.Stopwatch]::StartNew()
        while ($sw.Elapsed.TotalSeconds -lt 180) {
            if (Test-Path 'C:\vmtest\result.json') { Start-Sleep -Seconds 2; break }
            $info = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            # Ready again with no result file means it started and exited
            # without writing one, which is a different failure from a hang.
            if ($info -and $info.State -eq 'Ready' -and $sw.Elapsed.TotalSeconds -gt 10) {
                if (-not (Test-Path 'C:\vmtest\result.json')) {
                    $i = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue
                    $out.lastTaskResult = $i.LastTaskResult
                    $out.lastRunTime = "$($i.LastRunTime)"
                    break
                }
            }
            Start-Sleep -Seconds 2
        }
        $out.waitedSeconds = [int]$sw.Elapsed.TotalSeconds
        $out.producedResult = Test-Path 'C:\vmtest\result.json'

        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        $out
    } -ArgumentList $InstallDir, $GuestUser

    foreach ($k in $taskReport.Keys) { Write-Host ("    {0,-18} {1}" -f $k, $taskReport[$k]) }
    if ($taskReport.Contains('error')) { throw $taskReport.error }
    if (-not $taskReport.producedResult) {
        Write-Bad "the smoke test produced no result file after $($taskReport.waitedSeconds)s"
        if ($taskReport.Contains('lastTaskResult')) {
            Write-Bad "scheduled task exited with 0x$('{0:X}' -f [int]$taskReport.lastTaskResult)"
        }
    }

    # ------------------------------------------------------------ collect

    Write-Step 'Collect results'
    $resultsDir = Join-Path $ArtifactDir 'result'
    New-Item -ItemType Directory -Force -Path $resultsDir | Out-Null

    foreach ($f in 'result.json', 'menu.png') {
        try { Copy-Item "C:\vmtest\$f" $resultsDir -FromSession $session -Force -ErrorAction Stop }
        catch { Write-Bad "could not retrieve $f" }
    }
    try {
        Copy-Item (Join-Path $InstallDir 'shell.log') $resultsDir -FromSession $session -Force -ErrorAction Stop
    } catch { }

    $resultFile = Join-Path $resultsDir 'result.json'
    if (-not (Test-Path $resultFile)) {
        Write-Bad 'no result.json produced; the smoke test did not complete'
        Write-Bad 'check that the guest is logged in and auto-logon is enabled'
    }
    else {
        $r = Get-Content $resultFile -Raw | ConvertFrom-Json

        Write-Host ''
        foreach ($c in $r.checks) {
            if ($c.ok) { Write-Ok  "ok   $($c.name)" }
            else       { Write-Bad "FAIL $($c.name)$(if ($c.detail) { " -- $($c.detail)" })" }
        }

        Write-Host ''
        Write-Host "    menu items: $($r.menuItems -join ' | ')"
        if ($r.subMenuItems) { Write-Host "    submenu   : $($r.subMenuItems -join ' | ')" }

        Write-Host ''
        if ($r.passed) {
            Write-Ok "PASS  $($r.checks.Count) checks"
            $exitCode = 0
        }
        else {
            Write-Bad "FAIL  $($r.failures.Count) of $($r.checks.Count) checks"
            $r.failures | ForEach-Object { Write-Bad "      $_" }
        }
        Write-Host "`n    artifacts: $resultsDir"
    }
}
finally {
    if ($session) { Remove-PSSession $session -ErrorAction SilentlyContinue }
    if (-not $KeepRunning) {
        Write-Step 'Revert VM'
        Stop-VM -Name $VMName -TurnOff -Force -ErrorAction SilentlyContinue
        Restore-VMCheckpoint -VMName $VMName -Name $Checkpoint -Confirm:$false -ErrorAction SilentlyContinue
        Write-Ok "reverted to '$Checkpoint'"
    }
    else {
        Write-Host "`n    VM left running (-KeepRunning)"
    }
}

exit $exitCode
