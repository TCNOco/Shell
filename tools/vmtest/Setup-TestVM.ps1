#Requires -Version 5.1
<#
.SYNOPSIS
    Takes a fresh Windows 11 Hyper-V guest to a state the smoke test can drive,
    then creates the baseline checkpoint.

.DESCRIPTION
    Run once, elevated, on the host. Everything inside the guest is done over
    PowerShell Direct, so the VM needs no network.

    The smoke test opens a real context menu on a real desktop, which means the
    guest must have an interactive session already logged in when the test runs.
    That is what most of this script is arranging.

.PARAMETER VMName
    Existing Hyper-V VM. Quote it if the name contains spaces.

.PARAMETER Credential
    An account inside the guest that is a local administrator. If -CreateUser is
    given this account is created; otherwise it must already exist.

.NOTES
    Auto-logon stores the account password in plaintext under
    HKLM\...\Winlogon. That is how Windows auto-logon works and there is no way
    around it short of the LSA secret that Sysinternals Autologon uses. Only
    ever point this at a disposable test VM with a throwaway account.

.EXAMPLE
    .\Setup-TestVM.ps1 -VMName 'Windows 11 2025-10' -CreateUser
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $VMName,
    [pscredential] $Credential,
    [string] $GuestUser = 'tester',
    [string] $Checkpoint = 'clean',
    [switch] $CreateUser,
    [switch] $Force,
    [int] $BootTimeoutSec = 300,
    [string] $LogPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# $PSScriptRoot is normally populated, but it comes back empty when the script
# is launched through ShellExecute (Start-Process -Verb RunAs), which is exactly
# how this one gets elevated. Resolve the directory defensively rather than
# relying on it, and never in a param default where a failure aborts before the
# transcript that would explain it.
$scriptDir = $PSScriptRoot
if (-not $scriptDir -and $MyInvocation.MyCommand.Path) {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
}
if (-not $scriptDir) { $scriptDir = (Get-Location).Path }

if (-not $LogPath) { $LogPath = Join-Path $scriptDir 'runs\setup.log' }

# This usually runs in a separate elevated window, so transcribe it: the log is
# how anyone outside that window finds out what happened.
New-Item -ItemType Directory -Force -Path (Split-Path $LogPath -Parent) | Out-Null
try { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null } catch { }
Start-Transcript -Path $LogPath -Force | Out-Null
trap { Write-Host "FAILED: $($_.Exception.Message)" -ForegroundColor Red; Stop-Transcript | Out-Null; break }

function Write-Step { param([string] $m) Write-Host "`n=== $m" -ForegroundColor Cyan }
function Write-Ok   { param([string] $m) Write-Host "    $m" -ForegroundColor Green }
function Write-Bad  { param([string] $m) Write-Host "    $m" -ForegroundColor Red }
function Write-Note { param([string] $m) Write-Host "    $m" -ForegroundColor Yellow }

# ------------------------------------------------------------------ access

Write-Step 'Check Hyper-V access'
try { $null = Get-VM -ErrorAction Stop }
catch {
    throw @"
Cannot query Hyper-V: $($_.Exception.Message)

Run this from an elevated PowerShell, or add your account to the local
'Hyper-V Administrators' group so Hyper-V cmdlets work without elevation:

    Add-LocalGroupMember -Group 'Hyper-V Administrators' -Member '$env:USERNAME'

That change needs a sign-out to take effect.
"@
}
Write-Ok 'ok'

$vm = Get-VM -Name $VMName -ErrorAction Stop
Write-Ok "'$($vm.Name)'  state=$($vm.State)  gen=$($vm.Generation)  vcpu=$($vm.ProcessorCount)  mem=$([math]::Round($vm.MemoryStartup/1GB,1))GB"

$existing = Get-VMCheckpoint -VMName $VMName -ErrorAction SilentlyContinue
if ($existing) {
    Write-Note "existing checkpoints: $(($existing | ForEach-Object Name) -join ', ')"
}
if (($existing | Where-Object Name -eq $Checkpoint) -and -not $Force) {
    throw "Checkpoint '$Checkpoint' already exists. Pass -Force to replace it."
}

# The guest service interface is what PowerShell Direct rides on.
$gsi = Get-VMIntegrationService -VMName $VMName -Name 'Guest Service Interface' -ErrorAction SilentlyContinue
if ($gsi -and -not $gsi.Enabled) {
    Write-Note 'enabling Guest Service Interface'
    Enable-VMIntegrationService -VMName $VMName -Name 'Guest Service Interface'
}

if (-not $Credential) {
    $prompt = if ($CreateUser) {
        "Account to CREATE in '$VMName'. Choose any username and password; it becomes a throwaway local admin."
    } else {
        "The existing administrator account inside '$VMName' (the one you set up when installing Windows)."
    }
    $Credential = Get-Credential -UserName $(if ($CreateUser) { $GuestUser } else { '' }) -Message $prompt
}

# Two different things are needed from what was typed, and conflating them was
# a mistake: the credential must keep whatever qualified form the user supplied,
# because "MicrosoftAccount\someone@example.com" and "PCNAME\someone" both
# authenticate where the bare name may not. Only the *derived* pieces below get
# split apart, for the Winlogon values and the scheduled task principal.
$typedName = $Credential.UserName.Trim()

if ($typedName -match '^(?<dom>[^\\]+)\\(?<user>.+)$') {
    $GuestDomain = $Matches['dom'].Trim()
    $bareUser    = $Matches['user'].Trim()
}
else {
    $GuestDomain = $null       # resolved inside the guest once we are in
    $bareUser    = $typedName
}

if (-not $CreateUser -and -not $PSBoundParameters.ContainsKey('GuestUser')) {
    $GuestUser = $bareUser
    Write-Ok "signing in as '$typedName' (account '$GuestUser')"
}

# Rebuild only to drop stray whitespace, never to change the qualified form.
if ($Credential.UserName -ne $typedName) {
    $Credential = New-Object pscredential($typedName, $Credential.Password)
    Write-Note "trimmed whitespace from the username"
}

if ([string]::IsNullOrWhiteSpace($GuestUser)) {
    throw 'No guest username was supplied.'
}

# An empty password cannot authenticate over PowerShell Direct even if the
# account genuinely has none, so catch it here rather than letting it surface
# as an indistinguishable "credential is invalid".
if ([string]::IsNullOrEmpty($Credential.GetNetworkCredential().Password)) {
    throw @"
No password was entered for '$GuestUser'.

The prompt needs the password for that account *inside the VM*. If the account
genuinely has no password, PowerShell Direct still cannot use it: set one in the
guest, or create a dedicated account with

    .\Setup-TestVM.ps1 -VMName '$VMName' -CreateUser
"@
}

# ------------------------------------------------------------------- boot

Write-Step 'Start guest'

# Re-query rather than trusting the object captured earlier: a VM that was mid
# shutdown when this script started still reports Running for a while, and
# acting on that stale value means talking to a guest that is on its way down.
function Wait-StableState {
    param([int] $TimeoutSec = 180)
    $transitional = 'Stopping', 'Starting', 'Saving', 'Pausing', 'Resuming', 'Reset', 'Snapshotting'
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        $s = (Get-VM -Name $VMName).State
        if ($s -notin $transitional) { return $s }
        Write-Note "state=$s, waiting for it to settle"
        Start-Sleep -Seconds 3
    }
    throw "VM stayed in a transitional state for ${TimeoutSec}s"
}

$state = Wait-StableState
Write-Ok "state=$state"
if ($state -ne 'Running') {
    Start-VM -Name $VMName
    $state = Wait-StableState
    Write-Ok "started (state=$state)"
}

# The heartbeat service coming up is the signal that the guest OS is far enough
# along to authenticate anything. Without this the first credential attempt
# races the boot and fails for reasons that have nothing to do with the password.
function Wait-Heartbeat {
    param([int] $TimeoutSec = 240)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        $hb = Get-VMIntegrationService -VMName $VMName -Name Heartbeat -ErrorAction SilentlyContinue
        if ($hb -and $hb.PrimaryStatusDescription -eq 'OK') {
            Write-Ok "guest heartbeat OK after $([int]$sw.Elapsed.TotalSeconds)s"
            return $true
        }
        Start-Sleep -Seconds 3
    }
    Write-Note 'no guest heartbeat; continuing anyway'
    return $false
}

function Wait-Guest {
    param(
        [pscredential] $Cred,
        [int] $TimeoutSec,
        # Only safe on the first connection. During early boot the guest can
        # reject a perfectly good credential until the logon services are up,
        # so bailing on the first rejection after a reboot would abort a run
        # that was about to succeed.
        [switch] $FailFastOnBadCredential
    )
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $lastError = $null
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        try { return New-PSSession -VMName $VMName -Credential $Cred -ErrorAction Stop }
        catch {
            $lastError = $_.Exception.Message
            if ($FailFastOnBadCredential -and
                $lastError -match 'credential is invalid|user name or password|logon failure') {
                Write-Bad "guest rejected the credentials: $lastError"
                return $null
            }
            Start-Sleep -Seconds 5
        }
    }
    Write-Bad "timed out after ${TimeoutSec}s; last error: $lastError"
    return $null
}

Write-Step 'Connect over PowerShell Direct'
[void](Wait-Heartbeat)
$session = Wait-Guest -Cred $Credential -TimeoutSec $BootTimeoutSec -FailFastOnBadCredential

if (-not $session -and -not $CreateUser) {
    throw @"
Could not sign in to the VM as '$GuestUser'. The VM is '$((Get-VM -Name $VMName).State)'.

The account name is the usual culprit, and it is often not what the sign-in
screen shows. A Microsoft Account displays your full name but the actual
username is derived from your email, and it is that derived name which has to
be used here.

Inside the VM, open PowerShell and run:

    whoami

It prints COMPUTERNAME\username. Use the part after the backslash.

If that account is a Microsoft Account, PowerShell Direct usually cannot
authenticate it at all. Create a local one instead, in an elevated PowerShell
inside the VM:

    `$p = Read-Host 'Password' -AsSecureString
    New-LocalUser -Name shelltest -Password `$p -AccountNeverExpires -PasswordNeverExpires
    Add-LocalGroupMember -Group Administrators -Member shelltest

then re-run this script and sign in as 'shelltest'. A dedicated account is
worth having regardless: auto-logon stores whichever account you use in the
guest registry in plaintext.
"@
}

if (-not $session -and $CreateUser) {
    Write-Note 'could not sign in with that account; it may not exist yet'
    Write-Note 'supply an account that already works so the test account can be created'
    $bootstrap = Get-Credential -Message "An existing guest admin account for '$VMName'"
    $session = Wait-Guest -Cred $bootstrap -TimeoutSec 120
    if (-not $session) { throw 'could not connect to the guest with either account' }

    Write-Step "Create guest account '$GuestUser'"
    Invoke-Command -Session $session -ScriptBlock {
        param($user, $plain)
        $sec = ConvertTo-SecureString $plain -AsPlainText -Force
        if (-not (Get-LocalUser -Name $user -ErrorAction SilentlyContinue)) {
            New-LocalUser -Name $user -Password $sec -AccountNeverExpires -PasswordNeverExpires | Out-Null
        } else {
            Set-LocalUser -Name $user -Password $sec
        }
        Add-LocalGroupMember -Group 'Administrators' -Member $user -ErrorAction SilentlyContinue
    } -ArgumentList $GuestUser, $Credential.GetNetworkCredential().Password
    Write-Ok "created / updated '$GuestUser'"

    Remove-PSSession $session
    $session = Wait-Guest -Cred $Credential -TimeoutSec 120
}

if (-not $session) { throw "guest did not accept PowerShell Direct within ${BootTimeoutSec}s" }
Write-Ok 'connected'

try {
    # -------------------------------------------------------------- prepare

    Write-Step 'Configure guest'
    $report = Invoke-Command -Session $session -ScriptBlock {
        param($user, $plain, $explicitDomain)

        $out = [ordered]@{}

        # A Microsoft Account has no matching local user and needs
        # DefaultDomainName set to the literal "MicrosoftAccount" instead of the
        # machine name, so detect which kind of account this is first. An
        # explicit prefix from the caller wins over the guess.
        $isLocal = [bool](Get-LocalUser -Name $user -ErrorAction SilentlyContinue)
        $out.accountType = if ($isLocal) { "local ($user)" } else { "not a local user -- treating as Microsoft Account" }
        $domain = if ($explicitDomain) { $explicitDomain }
                  elseif ($isLocal)    { $env:COMPUTERNAME }
                  else                 { 'MicrosoftAccount' }
        $out.computerName = $env:COMPUTERNAME

        # Auto-logon. The smoke test needs an interactive session to exist
        # before it runs; without this there is no desktop to right-click.
        $wl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
        Set-ItemProperty $wl -Name AutoAdminLogon  -Value '1'   -Type String
        Set-ItemProperty $wl -Name DefaultUserName -Value $user -Type String
        Set-ItemProperty $wl -Name DefaultPassword -Value $plain -Type String
        Set-ItemProperty $wl -Name DefaultDomainName -Value $domain -Type String
        Remove-ItemProperty $wl -Name AutoLogonCount -ErrorAction SilentlyContinue
        $out.autoLogon = "configured (domain=$domain)"

        Set-ExecutionPolicy -Scope LocalMachine RemoteSigned -Force
        $out.executionPolicy = (Get-ExecutionPolicy -Scope LocalMachine).ToString()

        # Anything that blanks or locks the screen will break a synthesised
        # right-click, and a sleeping VM cannot be driven at all.
        $desk = 'HKCU:\Control Panel\Desktop'
        Set-ItemProperty $desk -Name ScreenSaveActive -Value '0' -Type String -ErrorAction SilentlyContinue
        Set-ItemProperty $desk -Name ScreenSaverIsSecure -Value '0' -Type String -ErrorAction SilentlyContinue
        powercfg /change monitor-timeout-ac 0  2>&1 | Out-Null
        powercfg /change standby-timeout-ac 0  2>&1 | Out-Null
        powercfg /change hibernate-timeout-ac 0 2>&1 | Out-Null
        $out.power = 'timeouts disabled'

        # Do not lock on resume.
        $sys = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization'
        New-Item $sys -Force | Out-Null
        Set-ItemProperty $sys -Name NoLockScreen -Value 1 -Type DWord

        # Explorer restarts constantly during testing; suppress the balloon and
        # keep folder windows in one process so the module check is unambiguous.
        $adv = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
        Set-ItemProperty $adv -Name SeparateProcess -Value 0 -Type DWord -ErrorAction SilentlyContinue

        $out.os = (Get-CimInstance Win32_OperatingSystem).Caption
        $out.build = "$([Environment]::OSVersion.Version) UBR=$((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').UBR)"
        $out.psVersion = $PSVersionTable.PSVersion.ToString()

        # A shell extension does not need to be signed to load, but Smart App
        # Control blocks unsigned binaries outright, so it has to be off.
        try {
            $sac = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' -Name VerifiedAndReputablePolicyState -ErrorAction Stop).VerifiedAndReputablePolicyState
        } catch { $sac = 0 }
        $out.smartAppControl = switch ($sac) { 0 { 'off' } 1 { 'ENFORCED' } 2 { 'evaluation' } default { "unknown($sac)" } }

        try { $out.defender = (Get-MpComputerStatus).RealTimeProtectionEnabled } catch { $out.defender = 'unknown' }

        $out
    } -ArgumentList $GuestUser, $Credential.GetNetworkCredential().Password, $GuestDomain

    foreach ($k in $report.Keys) { Write-Ok ("{0,-18} {1}" -f $k, $report[$k]) }

    if ($report.smartAppControl -eq 'ENFORCED') {
        Write-Bad 'Smart App Control is enforced in the guest and will block the unsigned build.'
        Write-Bad 'Turn it off in the guest (Windows Security > App & browser control), then re-run.'
    }
    if ($report.defender -eq $true) {
        Write-Note 'Defender real-time protection is on. The DLL patches import tables,'
        Write-Note 'which is exactly what heuristics look for. Consider excluding the'
        Write-Note 'install folder in the guest if you see spurious failures.'
    }

    # ---------------------------------------------------- verify auto-logon

    Write-Step 'Reboot and verify auto-logon'
    Invoke-Command -Session $session -ScriptBlock { Restart-Computer -Force }
    Remove-PSSession $session -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 15

    $session = Wait-Guest -Cred $Credential -TimeoutSec $BootTimeoutSec
    if (-not $session) { throw 'guest did not come back after reboot' }

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $loggedOn = $false
    while ($sw.Elapsed.TotalSeconds -lt 180) {
        $loggedOn = Invoke-Command -Session $session -ScriptBlock {
            # An explorer.exe owned by the target user means a real interactive
            # session exists, which is precisely what the smoke test needs.
            $p = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction SilentlyContinue
            [bool]($p | ForEach-Object { (Invoke-CimMethod -InputObject $_ -MethodName GetOwner).User } |
                   Where-Object { $_ })
        }
        if ($loggedOn) { break }
        Start-Sleep -Seconds 5
    }

    if ($loggedOn) { Write-Ok "interactive session present after $([int]$sw.Elapsed.TotalSeconds)s" }
    else {
        Write-Bad 'no interactive session found; auto-logon did not take effect.'
        Write-Bad 'The smoke test cannot run without one. Check the Winlogon values in the guest.'
        throw 'auto-logon verification failed'
    }

    # ------------------------------------------------------------ baseline

    Write-Step "Create checkpoint '$Checkpoint'"
    Remove-PSSession $session -ErrorAction SilentlyContinue
    $session = $null

    Stop-VM -Name $VMName -Force
    while ((Get-VM -Name $VMName).State -ne 'Off') { Start-Sleep -Seconds 2 }

    if ($existing | Where-Object Name -eq $Checkpoint) {
        Remove-VMCheckpoint -VMName $VMName -Name $Checkpoint -Confirm:$false
        Write-Note "replaced existing '$Checkpoint'"
    }
    Checkpoint-VM -Name $VMName -SnapshotName $Checkpoint
    Write-Ok "checkpoint '$Checkpoint' created"

    Write-Host ''
    Write-Ok 'Guest is ready. Run the loop with:'
    Write-Host ""
    Write-Host "    .\Invoke-VMTest.ps1 -VMName '$VMName' -GuestUser '$GuestUser'" -ForegroundColor White
    Write-Host ''
}
finally {
    if ($session) { Remove-PSSession $session -ErrorAction SilentlyContinue }
    Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
}
