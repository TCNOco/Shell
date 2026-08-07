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
    # All of these are top-level items in the test config, so a single
    # right-click is enough to see every one. Nothing here depends on a submenu
    # having been opened.
    [string[]] $ExpectedItems = @(
        'VMTEST_SENTINEL_ROOT',   # config parsed and the TrackPopupMenu hook fired
        'VMTEST_ASCII',
        'VMTEST_CJK_中',          # distinct from the next one only above the
        'VMTEST_CJK_渭',          #   low byte: the old _memicmp compared them equal
        'VMTEST_CYR_А',
        'VMTEST_CYR_а',
        'VMTEST_IMPORT_OK',       # a relative import resolved without the CWD hack
        'VMTEST_SENTINEL_MENU'    # the submenu itself exists, contents not asserted
    ),
    [int] $MenuTimeoutMs = 6000,
    # Repeated open/close cycles timed after the assertions, to give menu build
    # latency a number. 0 disables it.
    [int] $LatencySamples = 20
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
// Must marshal to exactly sizeof(INPUT): 40 bytes on x64, 28 on x86. SendInput
// validates the cbSize argument against its own sizeof and returns 0 without
// injecting anything if they disagree, so trailing padding fields here mean the
// click silently never happens.
[StructLayout(LayoutKind.Sequential)] public struct INPUT {
    public uint type; public MOUSEINPUT mi;
}

[DllImport("user32.dll", SetLastError=true)] public static extern uint SendInput(uint n, INPUT[] p, int cb);
[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
// The title is declared IntPtr, not string, so IntPtr.Zero passes a real NULL.
// PowerShell marshals $null into a string parameter as an empty string, which
// turns FindWindow(class, NULL) -- "any window of this class" -- into
// FindWindow(class, "") -- "a window of this class whose title is empty". The
// desktop's title is "Program Manager" and a popup menu's is not empty either,
// so both lookups silently found nothing.
[DllImport("user32.dll", CharSet=CharSet.Unicode, EntryPoint="FindWindowW")]
public static extern IntPtr FindWindowByClass(string cls, IntPtr title);
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

[DllImport("user32.dll", CharSet=CharSet.Unicode)]
public static extern IntPtr FindWindowExW(IntPtr parent, IntPtr after, string cls, IntPtr title);
[DllImport("user32.dll")] public static extern IntPtr GetTopWindow(IntPtr h);
[DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint cmd);
[DllImport("user32.dll", CharSet=CharSet.Unicode)]
public static extern int GetClassNameW(IntPtr h, System.Text.StringBuilder name, int max);
[DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint msg, IntPtr w, IntPtr l);
[DllImport("user32.dll", SetLastError=true)]
public static extern bool SystemParametersInfoW(uint action, uint param, ref uint val, uint winIni);

public const uint SPI_GETMENUSHOWDELAY = 0x006A;

public const uint GW_HWNDNEXT   = 2;
public const uint WM_CONTEXTMENU = 0x007B;
public const uint WM_KEYDOWN     = 0x0100;
public const uint WM_KEYUP       = 0x0101;
public const int  VK_ESCAPE      = 0x1B;

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

    # SPI_SETMENUSHOWDELAY is the submenu-on-hover delay, and it is a per-user
    # system setting, not ours. The extension used to overwrite it from config on
    # every menu open and restore it on close, which meant a user who had tuned
    # it down got it forced back up for as long as a menu was open, and left
    # permanently wrong if Explorer died in between. Sample it here and compare
    # after the menu has been opened and closed.
    $menuDelayBefore = 0
    [void][VmTest.Native]::SystemParametersInfoW([VmTest.Native]::SPI_GETMENUSHOWDELAY, 0, [ref]$menuDelayBefore, 0)
    $result.menuShowDelayBefore = $menuDelayBefore

    # Explorer loads a shell extension on demand, so before the first menu is
    # requested it may legitimately not be mapped yet. Record it here for
    # information; the assertion happens after the menu has been triggered,
    # which is the point at which it genuinely has to be loaded.
    $dllPath = Join-Path $InstallDir 'shell.dll'
    $result.dllMappedBeforeTrigger =
        [bool]($explorer.Modules | Where-Object { $_.FileName -ieq $dllPath })

    # 2. Open a context menu on the desktop and read it.
    # GetShellWindow is the authoritative handle for the desktop; the Progman
    # class lookup is only a fallback.
    $desktop = [VmTest.Native]::GetShellWindow()
    if ($desktop -eq [IntPtr]::Zero) {
        $desktop = [VmTest.Native]::FindWindowByClass('Progman', [IntPtr]::Zero)
    }
    Add-Check 'desktop window found' ($desktop -ne [IntPtr]::Zero)

    # Explorer delivers the desktop's context menu through the shell view's
    # list control, not through Progman itself: Progman -> SHELLDLL_DefView ->
    # SysListView32. When the desktop has a wallpaper slideshow the view is
    # reparented under a WorkerW instead, so look there too.
    $defView = [VmTest.Native]::FindWindowExW($desktop, [IntPtr]::Zero, 'SHELLDLL_DefView', [IntPtr]::Zero)
    if ($defView -eq [IntPtr]::Zero) {
        $worker = [IntPtr]::Zero
        while ($true) {
            $worker = [VmTest.Native]::FindWindowExW([IntPtr]::Zero, $worker, 'WorkerW', [IntPtr]::Zero)
            if ($worker -eq [IntPtr]::Zero) { break }
            $defView = [VmTest.Native]::FindWindowExW($worker, [IntPtr]::Zero, 'SHELLDLL_DefView', [IntPtr]::Zero)
            if ($defView -ne [IntPtr]::Zero) { break }
        }
    }
    $listView = [IntPtr]::Zero
    if ($defView -ne [IntPtr]::Zero) {
        $listView = [VmTest.Native]::FindWindowExW($defView, [IntPtr]::Zero, 'SysListView32', [IntPtr]::Zero)
    }
    $result.defView = "0x$('{0:X}' -f [int64]$defView)"
    $result.listView = "0x$('{0:X}' -f [int64]$listView)"
    Add-Check 'desktop shell view found' ($defView -ne [IntPtr]::Zero) `
        "SHELLDLL_DefView $($result.defView), SysListView32 $($result.listView)"

    [void][VmTest.Native]::SetForegroundWindow($desktop)
    Start-Sleep -Milliseconds 400

    $x = 400; $y = 400
    [void][VmTest.Native]::SetCursorPos($x, $y)
    Start-Sleep -Milliseconds 200

    # Confirm the cursor actually moved. SetCursorPos can be refused, and a
    # click at the wrong place looks identical to a click that did nothing.
    $pos = New-Object VmTest.Native+POINT
    [void][VmTest.Native]::GetCursorPos([ref]$pos)
    Add-Check 'cursor moved to the click point' (($pos.x -eq $x) -and ($pos.y -eq $y)) `
        "cursor at ($($pos.x),$($pos.y)), wanted ($x,$y)"

    $down = New-Object VmTest.Native+INPUT
    $down.type = 0
    $down.mi.dwFlags = [VmTest.Native]::MOUSEEVENTF_RIGHTDOWN
    $up = New-Object VmTest.Native+INPUT
    $up.type = 0
    $up.mi.dwFlags = [VmTest.Native]::MOUSEEVENTF_RIGHTUP

    $cb = [System.Runtime.InteropServices.Marshal]::SizeOf($down)
    $expectedCb = if ([IntPtr]::Size -eq 8) { 40 } else { 28 }
    Add-Check 'INPUT struct marshals to the right size' ($cb -eq $expectedCb) `
        "got $cb, want $expectedCb"

    # SendInput returns the number of events injected. Anything less than what
    # was asked for means no click happened, and every check after this becomes
    # meaningless, so it is asserted rather than discarded.
    $sent = [VmTest.Native]::SendInput(2, @($down, $up), $cb)
    Add-Check 'right-click injected' ($sent -eq 2) `
        "SendInput returned $sent of 2, last error $([System.Runtime.InteropServices.Marshal]::GetLastWin32Error())"

    # The popup is a standard #32768 window even though its items are owner-drawn.
    function Wait-Popup {
        param([int] $TimeoutMs)
        $w = [Diagnostics.Stopwatch]::StartNew()
        while ($w.ElapsedMilliseconds -lt $TimeoutMs) {
            $h = [VmTest.Native]::FindWindowByClass('#32768', [IntPtr]::Zero)
            if ($h -ne [IntPtr]::Zero -and [VmTest.Native]::IsWindowVisible($h)) { return $h }
            Start-Sleep -Milliseconds 100
        }
        return [IntPtr]::Zero
    }

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $popup = Wait-Popup -TimeoutMs $MenuTimeoutMs
    $result.trigger = 'sendinput'

    # Synthesised mouse input depends on focus, cursor position and the input
    # queue all cooperating. Posting WM_CONTEXTMENU to the desktop's list view
    # asks Explorer for the same menu without any of that, so it is a useful
    # second attempt and tells us which of the two mechanisms is at fault.
    if ($popup -eq [IntPtr]::Zero -and $listView -ne [IntPtr]::Zero) {
        $lparam = [IntPtr](($y -shl 16) -bor ($x -band 0xFFFF))
        [void][VmTest.Native]::PostMessageW($listView, [VmTest.Native]::WM_CONTEXTMENU, $listView, $lparam)
        $popup = Wait-Popup -TimeoutMs $MenuTimeoutMs
        if ($popup -ne [IntPtr]::Zero) { $result.trigger = 'wm_contextmenu' }
    }

    Add-Check 'context menu appeared' ($popup -ne [IntPtr]::Zero) `
        "waited $($sw.ElapsedMilliseconds)ms, trigger=$($result.trigger)"

    # Now the DLL genuinely has to be mapped: a menu was requested, so the shell
    # extension has had its reason to load. Re-read the module list rather than
    # reusing the snapshot taken before the trigger.
    $explorerNow = Get-Process -Id $result.explorerPid -ErrorAction SilentlyContinue
    $mappedNow = $false
    if ($explorerNow) {
        $explorerNow.Refresh()
        $mappedNow = [bool]($explorerNow.Modules | Where-Object { $_.FileName -ieq $dllPath })
    }
    Add-Check 'shell.dll mapped into explorer' $mappedNow `
        "before trigger=$($result.dllMappedBeforeTrigger), after=$mappedNow"

    # Captured unconditionally. Screenshotting only on success meant that every
    # failure so far produced no evidence of what was actually on screen, which
    # is precisely when it is needed.
    Start-Sleep -Milliseconds 500
    $result.screenshot = Save-Screenshot -Path $ScreenshotPath

    # If nothing showed up, record every visible top-level window class so the
    # next iteration has data instead of a hypothesis.
    if ($popup -eq [IntPtr]::Zero) {
        $classes = @()
        $h = [VmTest.Native]::GetTopWindow([IntPtr]::Zero)
        $guard = 0
        while ($h -ne [IntPtr]::Zero -and $guard -lt 400) {
            if ([VmTest.Native]::IsWindowVisible($h)) {
                $sb = New-Object System.Text.StringBuilder 256
                [void][VmTest.Native]::GetClassNameW($h, $sb, 256)
                $n = $sb.ToString()
                if ($n) { $classes += $n }
            }
            $h = [VmTest.Native]::GetWindow($h, [VmTest.Native]::GW_HWNDNEXT)
            $guard++
        }
        $result.visibleWindowClasses = @($classes | Select-Object -Unique)
    }

    if ($popup -ne [IntPtr]::Zero) {
        # Sampled with the menu still up, which is the only moment the override
        # is observable: the extension set the value on open and restored it on
        # close, so a before/after comparison alone sees nothing. This is the
        # value user32 uses to time submenu-on-hover for THIS menu.
        $menuDelayDuring = 0
        [void][VmTest.Native]::SystemParametersInfoW([VmTest.Native]::SPI_GETMENUSHOWDELAY, 0, [ref]$menuDelayDuring, 0)
        $result.menuShowDelayDuring = $menuDelayDuring
        Add-Check 'submenu delay not overridden while menu is open' `
            ($menuDelayDuring -eq $menuDelayBefore) `
            "system $menuDelayBefore ms, in-menu $menuDelayDuring ms"

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
    }

    # Close the menu. EndMenu only cancels a menu owned by the calling thread,
    # and this one belongs to Explorer, so posting Escape to the menu window is
    # what actually dismisses it. EndMenu is kept as a harmless fallback.
    if ($popup -ne [IntPtr]::Zero) {
        [void][VmTest.Native]::PostMessageW($popup, [VmTest.Native]::WM_KEYDOWN, [IntPtr][VmTest.Native]::VK_ESCAPE, [IntPtr]::Zero)
        [void][VmTest.Native]::PostMessageW($popup, [VmTest.Native]::WM_KEYUP, [IntPtr][VmTest.Native]::VK_ESCAPE, [IntPtr]::Zero)
    }
    [void][VmTest.Native]::EndMenu()
    Start-Sleep -Milliseconds 500

    # A menu left open would keep Explorer in a modal loop and make every check
    # below it unreliable.
    $stillOpen = [VmTest.Native]::FindWindowByClass('#32768', [IntPtr]::Zero)
    Add-Check 'menu closed cleanly' `
        ($stillOpen -eq [IntPtr]::Zero -or -not [VmTest.Native]::IsWindowVisible($stillOpen))

    # 3. Explorer survived. A restart means a crash, and the pid changes.
    $after = Get-Process explorer -ErrorAction SilentlyContinue |
             Where-Object { $_.Id -eq $result.explorerPid }
    Add-Check 'explorer survived the menu' ($null -ne $after) "pid $($result.explorerPid)"

    # Showing a menu must not have altered a system-wide user setting. This is
    # the assertion for the showdelay change: with no showdelay in config the
    # extension should never touch SPI_SETMENUSHOWDELAY at all.
    $menuDelayAfter = 0
    [void][VmTest.Native]::SystemParametersInfoW([VmTest.Native]::SPI_GETMENUSHOWDELAY, 0, [ref]$menuDelayAfter, 0)
    $result.menuShowDelayAfter = $menuDelayAfter
    Add-Check 'submenu show delay left alone' ($menuDelayAfter -eq $menuDelayBefore) `
        "before $menuDelayBefore ms, after $menuDelayAfter ms"

    # 4. Nothing was logged as an error. The DLL writes shell.log next to itself.
    $logPath = Join-Path $InstallDir 'shell.log'
    if (Test-Path $logPath) {
        $errors = @(Select-String -Path $logPath -Pattern '\[error\]' -ErrorAction SilentlyContinue |
                    ForEach-Object { $_.Line.Trim() })
        $result.logErrors = $errors
        Add-Check 'no errors in shell.log' ($errors.Count -eq 0) ($errors -join ' | ')

        # Warnings were previously invisible here, which is how "config file not
        # found" -- the reason the menu was the stock Windows one -- went
        # unreported across two runs while this check passed. For a
        # configuration that is supposed to load cleanly, a warning is a
        # failure.
        $warnings = @(Select-String -Path $logPath -Pattern '\[warning\]' -ErrorAction SilentlyContinue |
                      ForEach-Object { $_.Line.Trim() })
        $result.logWarnings = $warnings
        Add-Check 'no warnings in shell.log' ($warnings.Count -eq 0) ($warnings -join ' | ')
    }
    else {
        # No log at all means the extension never initialised far enough to
        # write its banner, which is itself a failure rather than a clean run.
        Add-Check 'shell.log was written' $false "expected $logPath"
    }

    # 5. No new crash report for explorer.
    $wer = Get-ChildItem "$env:ProgramData\Microsoft\Windows\WER\ReportQueue" -Directory -ErrorAction SilentlyContinue |
           Where-Object { $_.Name -like '*explorer.exe*' -and $_.CreationTime -gt (Get-Date).AddMinutes(-10) }
    Add-Check 'no explorer crash report' ($null -eq $wer -or @($wer).Count -eq 0)

    # 6. Menu build latency.
    #
    # Time from asking for the menu to the popup being visible. That interval
    # covers the work this project actually does per right-click: evaluating the
    # configuration, building the item tree and measuring it. Without a number
    # here, a codegen change like LTCG or a different allocator can only be
    # argued for on principle.
    #
    # WM_CONTEXTMENU is used rather than synthesised input because it is
    # deterministic and does not depend on cursor or focus state.
    if ($LatencySamples -gt 0 -and $listView -ne [IntPtr]::Zero) {
        $samples = @()
        $lparam = [IntPtr](($y -shl 16) -bor ($x -band 0xFFFF))

        for ($n = 0; $n -lt $LatencySamples; $n++) {
            # Make sure nothing is open before timing the next one.
            $t0 = [Diagnostics.Stopwatch]::StartNew()
            while ([VmTest.Native]::FindWindowByClass('#32768', [IntPtr]::Zero) -ne [IntPtr]::Zero -and
                   $t0.ElapsedMilliseconds -lt 2000) { Start-Sleep -Milliseconds 5 }

            $sw2 = [Diagnostics.Stopwatch]::StartNew()
            [void][VmTest.Native]::PostMessageW($listView, [VmTest.Native]::WM_CONTEXTMENU, $listView, $lparam)

            $h = [IntPtr]::Zero
            while ($sw2.ElapsedMilliseconds -lt 5000) {
                $c = [VmTest.Native]::FindWindowByClass('#32768', [IntPtr]::Zero)
                if ($c -ne [IntPtr]::Zero -and [VmTest.Native]::IsWindowVisible($c)) { $h = $c; break }
                Start-Sleep -Milliseconds 2
            }
            $sw2.Stop()

            if ($h -ne [IntPtr]::Zero) {
                $samples += [double]$sw2.Elapsed.TotalMilliseconds
                [void][VmTest.Native]::PostMessageW($h, [VmTest.Native]::WM_KEYDOWN, [IntPtr][VmTest.Native]::VK_ESCAPE, [IntPtr]::Zero)
                [void][VmTest.Native]::PostMessageW($h, [VmTest.Native]::WM_KEYUP, [IntPtr][VmTest.Native]::VK_ESCAPE, [IntPtr]::Zero)
            }
            Start-Sleep -Milliseconds 60
        }

        if ($samples.Count -ge 3) {
            $sorted = $samples | Sort-Object
            # The first sample carries one-off initialisation (config parse,
            # font setup) and is reported separately rather than averaged in.
            $warm = $samples[1..($samples.Count - 1)] | Sort-Object
            $result.latency = [ordered]@{
                samples = $samples.Count
                coldMs  = [math]::Round($samples[0], 1)
                minMs   = [math]::Round($warm[0], 1)
                medianMs= [math]::Round($warm[[int]($warm.Count / 2)], 1)
                maxMs   = [math]::Round($warm[-1], 1)
                allMs   = @($samples | ForEach-Object { [math]::Round($_, 1) })
            }
            Write-Host ("  menu latency: cold {0}ms, warm min {1}ms median {2}ms max {3}ms over {4} samples" -f
                        $result.latency.coldMs, $result.latency.minMs, $result.latency.medianMs,
                        $result.latency.maxMs, $samples.Count)
        }
        Add-Check 'latency samples collected' ($samples.Count -ge 3) "$($samples.Count) of $LatencySamples"
    }
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
