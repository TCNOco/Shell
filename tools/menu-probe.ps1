#Requires -Version 5.1
<#
.SYNOPSIS
    Build, install, open a context menu in each host, and report what the DLL
    logged - without a human opening menus by hand.

.DESCRIPTION
    The menu only misbehaves in a live host, so every change has needed a build,
    an elevated install, a menu opened in two applications and a read of the log.
    That loop is the slow part, not the thinking, and doing it by hand also loses
    which log line belongs to which attempt.

    This drives the whole cycle and prints the two teardown lines side by side.

    It synthesises a real right-click, because a posted WM_CONTEXTMENU does not
    reproduce what a host actually does. That moves the pointer: it is put back
    afterwards, but do not type during a run.

.PARAMETER SkipBuild
    Use the DLL already in src\bin.

.PARAMETER SkipInstall
    Probe whatever is installed. Without this the script needs elevation.

.PARAMETER Hosts
    Which hosts to probe. Default: both.

.EXAMPLE
    tools\menu-probe.ps1
#>
[CmdletBinding()]
param(
    [switch] $SkipBuild,
    [switch] $SkipInstall,
    [ValidateSet('treesize', 'explorer')]
    [string[]] $Hosts = @('treesize', 'explorer')
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$log  = 'C:\Program Files\TCNO Nilesoft Shell\shell.log'

if (-not ('MenuProbe.Native' -as [type])) {
    $src = @'
using System;
using System.Runtime.InteropServices;
namespace MenuProbe {
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int x, y; }
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int left, top, right, bottom; }
  public static class Native {
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, IntPtr e);
    [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint f, IntPtr e);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindowW(string c, string t);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern IntPtr GetShellWindow();
  }
}
'@
    # csc reads LIB and INCLUDE and treats a stale entry as a warning, which it
    # then treats as an error - so an unrelated toolchain left on PATH stops this
    # compiling. Neither is needed here.
    $savedLib = $env:LIB; $savedInc = $env:INCLUDE
    try {
        $env:LIB = ''; $env:INCLUDE = ''
        Add-Type -TypeDefinition $src -ErrorAction Stop
    }
    finally { $env:LIB = $savedLib; $env:INCLUDE = $savedInc }
}

$MOUSEEVENTF_RIGHTDOWN = 0x0008
$MOUSEEVENTF_RIGHTUP   = 0x0010
$KEYEVENTF_KEYUP       = 0x0002
$VK_ESCAPE             = 0x1B

function Invoke-MenuAt {
    param([int] $X, [int] $Y, [int] $HoverSteps = 6)

    $saved = New-Object MenuProbe.POINT
    [void][MenuProbe.Native]::GetCursorPos([ref]$saved)
    try {
        [void][MenuProbe.Native]::SetCursorPos($X, $Y)
        Start-Sleep -Milliseconds 250
        [MenuProbe.Native]::mouse_event($MOUSEEVENTF_RIGHTDOWN, 0, 0, 0, [IntPtr]::Zero)
        [MenuProbe.Native]::mouse_event($MOUSEEVENTF_RIGHTUP, 0, 0, 0, [IntPtr]::Zero)
        Start-Sleep -Milliseconds 900

        # Walk down the menu. Hover is what produces the repaints that separate a
        # host which redraws from one which does not, so a probe that only opens
        # and closes would miss the difference the counters are there to show.
        for ($i = 1; $i -le $HoverSteps; $i++) {
            [void][MenuProbe.Native]::SetCursorPos($X + 40, $Y + (28 * $i))
            Start-Sleep -Milliseconds 120
        }

        Start-Sleep -Milliseconds 300
        [MenuProbe.Native]::keybd_event($VK_ESCAPE, 0, 0, [IntPtr]::Zero)
        [MenuProbe.Native]::keybd_event($VK_ESCAPE, 0, $KEYEVENTF_KEYUP, [IntPtr]::Zero)
        Start-Sleep -Milliseconds 700
    }
    finally {
        [void][MenuProbe.Native]::SetCursorPos($saved.x, $saved.y)
    }
}

function Restart-TreeSize {
    # The DLL is loaded into a host once and stays for the life of the process, so
    # installing while the host is running leaves it testing the previous build.
    # That is invisible in the result - the menu just misbehaves the same way - so
    # restart rather than trusting that the newest binary is the one under test.
    $p = Get-Process -Name 'TreeSize*' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $p) { return }

    $exe = try { $p.Path } catch { $null }
    if (-not $exe) {
        Write-Warning 'TreeSize path unavailable; leaving it running (it may hold an older DLL).'
        return
    }

    Write-Host "    restarting TreeSize to load the new DLL"
    $p | Stop-Process -Force
    Start-Sleep -Seconds 2
    Start-Process $exe
    Start-Sleep -Seconds 6
}

function Probe-TreeSize {
    $p = Get-Process -Name 'TreeSize*' -ErrorAction SilentlyContinue |
         Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
    if (-not $p) { Write-Warning 'TreeSize is not running - start it and re-run.'; return $false }

    $h = $p.MainWindowHandle
    [void][MenuProbe.Native]::SetForegroundWindow($h)
    Start-Sleep -Milliseconds 600

    $r = New-Object MenuProbe.RECT
    [void][MenuProbe.Native]::GetWindowRect($h, [ref]$r)
    # Inside the file list rather than the toolbar or the frame.
    Invoke-MenuAt -X ($r.left + 220) -Y ($r.top + 320)
    return $true
}

function Probe-Explorer {
    # GetShellWindow first: FindWindow('Progman') misses the desktop whenever the
    # wallpaper slideshow has reparented it under a WorkerW, which is why the
    # Explorer half of the first automated run reported nothing to probe.
    $prog = [MenuProbe.Native]::GetShellWindow()
    if ($prog -eq [IntPtr]::Zero) {
        $prog = [MenuProbe.Native]::FindWindowW('Progman', 'Program Manager')
    }
    if ($prog -eq [IntPtr]::Zero) { Write-Warning 'desktop window not found'; return $false }
    [void][MenuProbe.Native]::SetForegroundWindow($prog)
    Start-Sleep -Milliseconds 600

    $r = New-Object MenuProbe.RECT
    [void][MenuProbe.Native]::GetWindowRect($prog, [ref]$r)
    Invoke-MenuAt -X ($r.left + 400) -Y ($r.top + 400)
    return $true
}

function Show-NewLines {
    param([string] $Label)

    if (-not (Test-Path $log)) { Write-Warning "no log at $log"; return }
    $lines = @(Get-Content $log | Select-String 'menu teardown')
    if (-not $lines) { Write-Warning 'no teardown lines in the log at all'; return }

    $line = $lines[-1].Line
    Write-Host ''
    Write-Host "--- $Label" -ForegroundColor Cyan

    # The whole line, always. Picking fields out by name hid showpaint= entirely
    # when it was missing, which read as "the counter is zero" when it actually
    # meant the host was still running an older DLL.
    Write-Host ("  " + ($line -replace '^\d{4}-\d\d-\d\d ', '')) -ForegroundColor DarkGray

    foreach ($f in 'drawitem=\d+', 'drawvis=\d+', 'showpaint=\d+', 'clip=\S+', 'px_item=\S+') {
        $m = [regex]::Match($line, $f)
        if ($m.Success) { Write-Host ("  " + $m.Value) -ForegroundColor Yellow }
        else            { Write-Host ("  " + ($f -replace '\\S\+|\\d\+', '') + "MISSING - host is running an older DLL") -ForegroundColor Red }
    }
}

if (-not $SkipBuild) {
    Write-Host '=== build' -ForegroundColor Cyan
    & (Join-Path $root 'build.ps1') | Select-String -Pattern 'error C|error MSB|shell\.dll ' |
        ForEach-Object { Write-Host "    $_" }
}

if (-not $SkipInstall) {
    Write-Host '=== install' -ForegroundColor Cyan
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $isAdmin = (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
                   [Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        throw "Run this elevated - the install writes to Program Files and HKLM.`n" +
              "  Start-Process powershell -Verb RunAs -ArgumentList '-NoExit','-File','$PSCommandPath'"
    }
    & (Join-Path $root 'tools\install-local.ps1') | Select-Object -Last 3 |
        ForEach-Object { Write-Host "    $_" }
    Start-Sleep -Seconds 3
    Restart-TreeSize
}

foreach ($h in $Hosts) {
    Write-Host ''
    Write-Host "=== probe $h" -ForegroundColor Cyan
    $ok = switch ($h) {
        'treesize' { Probe-TreeSize }
        'explorer' { Probe-Explorer }
    }
    # Printed after each probe, so the newest teardown line is this host's.
    if ($ok) { Show-NewLines -Label $h }
}

Write-Host ''
Write-Host 'done.' -ForegroundColor Green
