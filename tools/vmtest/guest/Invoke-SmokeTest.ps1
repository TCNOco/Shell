#Requires -Version 5.1
<#
.SYNOPSIS
    Opens a real context menu and asserts on what is actually in it.

.DESCRIPTION
    Runs inside the guest, in the interactive desktop session. PowerShell Direct
    creates a non-interactive session, so this cannot be invoked directly across
    the VM boundary; Invoke-VMTest.ps1 registers it as a scheduled task running
    as the logged-on user and waits for the result file.

    Menu items are read through Win32 rather than UI Automation. The shell
    extension owner-draws its items but still sets MIIM_STRING with the title in
    dwTypeData, so GetMenuItemInfoW returns real text, which is both simpler and
    far more reliable than driving an accessibility tree.

.OUTPUTS
    A JSON result document at -ResultPath. Exit code is the number of failed
    assertions.
#>
[CmdletBinding()]
param(
    [string] $InstallDir = 'C:\Program Files\TCNO Nilesoft Shell',
    [string] $ResultPath = 'C:\vmtest\result.json',
    [string] $ScreenshotPath = 'C:\vmtest\menu.png',
    [string[]] $ExpectedItems = @(
        'VMTEST_SENTINEL_ROOT',
        'VMTEST_SENTINEL_MENU'
    ),
    [string[]] $ExpectedSubItems = @(
        'VMTEST_ASCII',
        'VMTEST_CJK_中',
        'VMTEST_CJK_渭',
        'VMTEST_CYR_А',
        'VMTEST_CYR_а',
        'VMTEST_IMPORT_OK'
    ),
    [int] $MenuTimeoutMs = 6000
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Add-Type shells out to the C# compiler, which treats a stale or invalid LIB or
# INCLUDE as a warning-as-error and fails before compiling anything. A developer
# machine that has ever run vcvars can carry one of these; clear them so the
# P/Invoke block below always compiles.
$env:LIB = ''
$env:INCLUDE = ''

# NOTE: this file must stay UTF-8 with a BOM. Windows PowerShell 5.1 reads a
# BOM-less .ps1 as ANSI, which would silently mangle the CJK and Cyrillic
# sentinels below into something no assertion could ever match.

$result = [ordered]@{
    startedUtc   = (Get-Date).ToUniversalTime().ToString('o')
    passed       = $false
    failures     = New-Object System.Collections.ArrayList
    checks       = New-Object System.Collections.ArrayList
    menuItems    = @()
    subMenuItems = @()
    logErrors    = @()
    explorerPid  = $null
    screenshot   = $null
}

function Add-Check {
    param([string] $Name, [bool] $Ok, [string] $Detail = '')
    $null = $result.checks.Add([ordered]@{ name = $Name; ok = $Ok; detail = $Detail })
    if (-not $Ok) { $null = $result.failures.Add("$Name : $Detail") }
    Write-Host ("{0} {1}{2}" -f $(if ($Ok) { '  ok  ' } else { ' FAIL ' }), $Name,
                $(if ($Detail) { " -- $Detail" } else { '' }))
}

Add-Type -Namespace VmTest -Name Native -UsingNamespace System.Text -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)] public struct POINT { public int x, y; }

[StructLayout(LayoutKind.Sequential)]
public struct MENUITEMINFO {
    public int cbSize, fMask, fType, fState, wID;
    public IntPtr hSubMenu, hbmpChecked, hbmpUnchecked;
    public IntPtr dwItemData;
    public IntPtr dwTypeData;
    public int cch;
    public IntPtr hbmpItem;
}

[StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT {
    public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr dwExtraInfo;
}
[StructLayout(LayoutKind.Sequential)] public struct INPUT {
    public uint type; public MOUSEINPUT mi; public int pad1, pad2;
}

[DllImport("user32.dll", SetLastError=true)] public static extern uint SendInput(uint n, INPUT[] p, int cb);
[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindowW(string cls, string title);
[DllImport("user32.dll")] public static extern IntPtr SendMessageW(IntPtr h, uint msg, IntPtr w, IntPtr l);
[DllImport("user32.dll")] public static extern int GetMenuItemCount(IntPtr hMenu);
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern bool GetMenuItemInfoW(IntPtr hMenu, uint item, bool byPos, ref MENUITEMINFO mii);
[DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int left, top, right, bottom; }

// GetShellWindow returns the desktop's shell window, so its owning process is
// the Explorer actually running the desktop rather than whichever instance
// happens to be oldest.
[DllImport("user32.dll")] public static extern IntPtr GetShellWindow();
[DllImport("user32.dll")] public static extern int GetWindowThreadProcessId(IntPtr h, out int pid);
// Cancels the active menu without depending on synthesised keystrokes.
[DllImport("user32.dll")] public static extern bool EndMenu();

public const uint MN_GETHMENU     = 0x01E1;
public const uint MIIM_STRING     = 0x00000040;
public const uint MIIM_SUBMENU    = 0x00000004;
public const uint MIIM_FTYPE      = 0x00000100;
public const uint MFT_SEPARATOR   = 0x00000800;
public const uint MOUSEEVENTF_RIGHTDOWN = 0x0008;
public const uint MOUSEEVENTF_RIGHTUP   = 0x0010;
'@

function Get-MenuItems {
    param([IntPtr] $HMenu, [int] $Depth = 0)

    $items = @()
    if ($HMenu -eq [IntPtr]::Zero) { return $items }

    $count = [VmTest.Native]::GetMenuItemCount($HMenu)
    for ($i = 0; $i -lt $count; $i++) {

        $buf = New-Object System.Text.StringBuilder 1024
        $ptr = [System.Runtime.InteropServices.Marshal]::AllocHGlobal(2048)
        try {
            $mii = New-Object VmTest.Native+MENUITEMINFO
            $mii.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf($mii)
            $mii.fMask = [int]([VmTest.Native]::MIIM_STRING -bor [VmTest.Native]::MIIM_SUBMENU -bor [VmTest.Native]::MIIM_FTYPE)
            $mii.dwTypeData = $ptr
            $mii.cch = 1023

            if ([VmTest.Native]::GetMenuItemInfoW($HMenu, [uint32]$i, $true, [ref]$mii)) {
                $text = ''
                if ($mii.cch -gt 0) {
                    $text = [System.Runtime.InteropServices.Marshal]::PtrToStringUni($ptr, $mii.cch)
                }
                $isSep = (($mii.fType -band [int][VmTest.Native]::MFT_SEPARATOR) -ne 0)
                $items += [ordered]@{
                    index     = $i
                    depth     = $Depth
                    text      = $text
                    separator = $isSep
                    hasSub    = ($mii.hSubMenu -ne [IntPtr]::Zero)
                }
                # Submenus are populated lazily on WM_INITMENUPOPUP, so children
                # may legitimately be empty until the user hovers. One level is
                # enough to prove the tree was built.
                if ($mii.hSubMenu -ne [IntPtr]::Zero -and $Depth -lt 1) {
                    $items += Get-MenuItems -HMenu $mii.hSubMenu -Depth ($Depth + 1)
                }
            }
        }
        finally {
            [System.Runtime.InteropServices.Marshal]::FreeHGlobal($ptr)
            $buf = $null
        }
    }
    return $items
}

function Save-Screenshot {
    param([string] $Path)
    try {
        Add-Type -AssemblyName System.Drawing, System.Windows.Forms
        $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
        $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen($b.Location, [System.Drawing.Point]::Empty, $b.Size)
        $dir = Split-Path $Path -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
        $g.Dispose(); $bmp.Dispose()
        return $Path
    }
    catch {
        Write-Host "screenshot failed: $($_.Exception.Message)"
        return $null
    }
}

# ---------------------------------------------------------------- assertions

try {
    New-Item -ItemType Directory -Force -Path (Split-Path $ResultPath -Parent) | Out-Null

    # 1. Explorer is running and has our DLL mapped. If the DLL is not in the
    #    module list nothing downstream can pass, so this is checked first.
    #
    #    The process is identified through GetShellWindow rather than by picking
    #    the oldest explorer.exe: only one instance owns the desktop, and
    #    checking a different one would report a missing DLL that is in fact
    #    loaded exactly where it should be.
    $explorer = $null
    $shellWnd = [VmTest.Native]::GetShellWindow()
    if ($shellWnd -ne [IntPtr]::Zero) {
        $shellPid = 0
        [void][VmTest.Native]::GetWindowThreadProcessId($shellWnd, [ref]$shellPid)
        if ($shellPid -ne 0) {
            $explorer = Get-Process -Id $shellPid -ErrorAction SilentlyContinue
        }
    }
    if (-not $explorer) {
        # No shell window yet: fall back so the failure is reported against a
        # real process rather than as a bare null.
        $explorer = Get-Process explorer -ErrorAction SilentlyContinue |
                    Sort-Object StartTime | Select-Object -First 1
    }
    Add-Check 'explorer owns the desktop' ($null -ne $explorer) `
        "shell window 0x$('{0:X}' -f [int64]$shellWnd)"
    if (-not $explorer) { throw 'no explorer.exe owning a desktop' }
    $result.explorerPid = $explorer.Id

    $dllPath = Join-Path $InstallDir 'shell.dll'
    $loaded = $explorer.Modules | Where-Object { $_.FileName -ieq $dllPath }
    Add-Check 'shell.dll loaded into explorer' ($null -ne $loaded) $dllPath

    # 2. Open a context menu on the desktop and read it.
    $desktop = [VmTest.Native]::FindWindowW('Progman', $null)
    Add-Check 'desktop window found' ($desktop -ne [IntPtr]::Zero)
    [void][VmTest.Native]::SetForegroundWindow($desktop)
    Start-Sleep -Milliseconds 400

    $x = 400; $y = 400
    [void][VmTest.Native]::SetCursorPos($x, $y)
    Start-Sleep -Milliseconds 200

    $down = New-Object VmTest.Native+INPUT
    $down.type = 0
    $down.mi.dwFlags = [VmTest.Native]::MOUSEEVENTF_RIGHTDOWN
    $up = New-Object VmTest.Native+INPUT
    $up.type = 0
    $up.mi.dwFlags = [VmTest.Native]::MOUSEEVENTF_RIGHTUP
    [void][VmTest.Native]::SendInput(2, @($down, $up), [System.Runtime.InteropServices.Marshal]::SizeOf($down))

    # The popup is a standard #32768 window even though its items are owner-drawn.
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $popup = [IntPtr]::Zero
    while ($sw.ElapsedMilliseconds -lt $MenuTimeoutMs) {
        $h = [VmTest.Native]::FindWindowW('#32768', $null)
        if ($h -ne [IntPtr]::Zero -and [VmTest.Native]::IsWindowVisible($h)) { $popup = $h; break }
        Start-Sleep -Milliseconds 100
    }
    Add-Check 'context menu appeared' ($popup -ne [IntPtr]::Zero) "waited $($sw.ElapsedMilliseconds)ms"

    if ($popup -ne [IntPtr]::Zero) {
        Start-Sleep -Milliseconds 500
        $result.screenshot = Save-Screenshot -Path $ScreenshotPath

        $hMenu = [VmTest.Native]::SendMessageW($popup, [VmTest.Native]::MN_GETHMENU, [IntPtr]::Zero, [IntPtr]::Zero)
        Add-Check 'menu handle retrieved' ($hMenu -ne [IntPtr]::Zero)

        $items = @(Get-MenuItems -HMenu $hMenu)
        $result.menuItems = @($items | Where-Object { $_.depth -eq 0 } | ForEach-Object { $_.text })
        $result.subMenuItems = @($items | Where-Object { $_.depth -gt 0 } | ForEach-Object { $_.text })
        $all = @($items | ForEach-Object { $_.text })

        Add-Check 'menu is not empty' ($items.Count -gt 0) "$($items.Count) items"

        foreach ($expect in $ExpectedItems) {
            Add-Check "top-level item '$expect'" ($all -contains $expect)
        }
        foreach ($expect in $ExpectedSubItems) {
            # Submenu contents only materialise once the popup is opened, so a
            # miss here is reported but does not by itself mean a regression;
            # the orchestrator decides based on whether any were found at all.
            Add-Check "submenu item '$expect'" ($all -contains $expect)
        }
    }

    # Close the menu and let Explorer settle. EndMenu cancels the active menu
    # directly; SendKeys would depend on System.Windows.Forms having been loaded
    # by the screenshot helper, which does not run if the screenshot failed, and
    # on the keystroke reaching the right window.
    [void][VmTest.Native]::EndMenu()
    Start-Sleep -Milliseconds 300

    # A menu left open would keep Explorer in a modal loop and make every check
    # below it unreliable.
    $stillOpen = [VmTest.Native]::FindWindowW('#32768', $null)
    Add-Check 'menu closed cleanly' `
        ($stillOpen -eq [IntPtr]::Zero -or -not [VmTest.Native]::IsWindowVisible($stillOpen))

    # 3. Explorer survived. A restart means a crash, and the pid changes.
    $after = Get-Process explorer -ErrorAction SilentlyContinue |
             Where-Object { $_.Id -eq $result.explorerPid }
    Add-Check 'explorer survived the menu' ($null -ne $after) "pid $($result.explorerPid)"

    # 4. Nothing was logged as an error. The DLL writes shell.log next to itself.
    $logPath = Join-Path $InstallDir 'shell.log'
    if (Test-Path $logPath) {
        $errors = @(Select-String -Path $logPath -Pattern '\berror\b' -SimpleMatch:$false -ErrorAction SilentlyContinue |
                    ForEach-Object { $_.Line.Trim() })
        $result.logErrors = $errors
        Add-Check 'no errors in shell.log' ($errors.Count -eq 0) ($errors -join ' | ')
    }
    else {
        Add-Check 'no errors in shell.log' $true 'no log file written'
    }

    # 5. No new crash report for explorer.
    $wer = Get-ChildItem "$env:ProgramData\Microsoft\Windows\WER\ReportQueue" -Directory -ErrorAction SilentlyContinue |
           Where-Object { $_.Name -like '*explorer.exe*' -and $_.CreationTime -gt (Get-Date).AddMinutes(-10) }
    Add-Check 'no explorer crash report' ($null -eq $wer -or @($wer).Count -eq 0)
}
catch {
    $null = $result.failures.Add("unhandled: $($_.Exception.Message)")
    Write-Host "EXCEPTION: $($_.Exception.Message)"
}
finally {
    $result.passed = ($result.failures.Count -eq 0)
    $result.finishedUtc = (Get-Date).ToUniversalTime().ToString('o')
    $result | ConvertTo-Json -Depth 6 | Set-Content -Path $ResultPath -Encoding UTF8
    Write-Host ""
    Write-Host ("{0}: {1} check(s), {2} failure(s)" -f
                $(if ($result.passed) { 'PASS' } else { 'FAIL' }),
                $result.checks.Count, $result.failures.Count)
}

exit $result.failures.Count
