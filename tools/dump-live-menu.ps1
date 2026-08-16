#Requires -Version 5.1
<#
.SYNOPSIS
    Read back the popup menu that is on screen right now.

.DESCRIPTION
    Settles one question: when a host shows a blank menu, is the text missing
    from the menu data, or only from the painting?

    The visible popup is ours - ContextMenu creates its own HMENU and the hook
    tracks that, not the host's - so every visible row is a MenuItemInfo we
    inserted. GetMenuItemInfoW therefore returns exactly the string we gave it.

      rows have text  -> the data is fine and the paint path is at fault.
                         Every string in the DLL goes through one call,
                         DrawThemeTextEx, gated on _hTheme; a null _hTheme
                         erases all text and nothing else.

      rows are empty  -> the titles never got harvested, and the fault is in
                         build_system_menuitems, not in drawing.

    Run it, then open the menu in the host. It polls for a #32768 window and
    dumps whatever it finds. Read-only: it sends MN_GETHMENU and reads item
    info, nothing else.

    If the host runs elevated, run this elevated too - UIPI blocks a
    medium-integrity process from messaging an elevated window, and you would
    get a false "no menu found".

.PARAMETER Seconds
    How long to wait for a popup to appear. Default 20.
#>
[CmdletBinding()]
param([int] $Seconds = 20)

# -TypeDefinition with an explicit try/catch: -MemberDefinition failed on this
# machine and the only symptom was "Unable to find type [LiveMenu.Native]" from
# the call sites, with the real compiler error nowhere in sight.
if (-not ('LiveMenu.Native' -as [type])) {
    $src = @'
using System;
using System.Runtime.InteropServices;
namespace LiveMenu {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int left, top, right, bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int x, y; }
  [StructLayout(LayoutKind.Sequential)]
  public struct MENUITEMINFO {
    public int cbSize; public int fMask; public int fType; public int fState; public int wID;
    public IntPtr hSubMenu; public IntPtr hbmpChecked; public IntPtr hbmpUnchecked;
    public IntPtr dwItemData; public IntPtr dwTypeData; public int cch; public IntPtr hbmpItem;
  }
  public static class Native {
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern IntPtr FindWindowW(string cls, string title);
    [DllImport("user32.dll", SetLastError=true)]
    public static extern IntPtr SendMessageW(IntPtr h, uint msg, IntPtr wp, IntPtr lp);
    [DllImport("user32.dll", SetLastError=true)]
    public static extern int GetMenuItemCount(IntPtr hMenu);
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern bool GetMenuItemInfoW(IntPtr hMenu, uint item, bool byPos, ref MENUITEMINFO mii);
    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern int GetWindowLongW(IntPtr h, int i);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, System.Text.StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint cmd);
    [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
  }
}
'@
    # The C# compiler reads LIB and INCLUDE, and reports a non-existent entry as
    # a warning - which it then treats as an error, so an unrelated stale path
    # left behind by some other toolchain stops this script compiling. Neither
    # variable is needed here: nothing outside the framework is referenced.
    # Cleared for the duration and put back afterwards.
    $savedLib = $env:LIB
    $savedInc = $env:INCLUDE
    try {
        $env:LIB = ''
        $env:INCLUDE = ''
        Add-Type -TypeDefinition $src -ErrorAction Stop
    }
    catch {
        Write-Error "could not compile the interop types: $($_.Exception.Message)"
        exit 3
    }
    finally {
        $env:LIB = $savedLib
        $env:INCLUDE = $savedInc
    }
}
if (-not ('LiveMenu.Native' -as [type])) { Write-Error 'interop types still unavailable'; exit 3 }

$MN_GETHMENU   = 0x01E1
$MIIM_STATE    = 0x00000001
$MIIM_ID       = 0x00000002
$MIIM_SUBMENU  = 0x00000004
$MIIM_FTYPE    = 0x00000100
$MIIM_STRING   = 0x00000040
$MIIM_DATA     = 0x00000020
$MFT_OWNERDRAW = 0x00000100
$MFT_SEPARATOR = 0x00000800

Write-Host "waiting up to $Seconds s for a popup menu - open it now..." -ForegroundColor Cyan

$deadline = (Get-Date).AddSeconds($Seconds)
$hwnd = [IntPtr]::Zero
while ((Get-Date) -lt $deadline) {
    $h = [LiveMenu.Native]::FindWindowW('#32768', $null)
    if ($h -ne [IntPtr]::Zero -and [LiveMenu.Native]::IsWindowVisible($h)) { $hwnd = $h; break }
    Start-Sleep -Milliseconds 150
}

if ($hwnd -eq [IntPtr]::Zero) {
    Write-Warning 'no visible #32768 popup found.'
    Write-Warning 'if the host is elevated, run this elevated too - UIPI hides its windows otherwise.'
    exit 2
}

$hMenu = [LiveMenu.Native]::SendMessageW($hwnd, $MN_GETHMENU, [IntPtr]::Zero, [IntPtr]::Zero)
if ($hMenu -eq [IntPtr]::Zero) { Write-Warning "MN_GETHMENU returned null for window $hwnd"; exit 2 }

$count = [LiveMenu.Native]::GetMenuItemCount($hMenu)
Write-Host "popup $hwnd  hMenu $hMenu  items: $count" -ForegroundColor Green
Write-Host ''

$withText = 0; $blank = 0; $seps = 0
for ($i = 0; $i -lt $count; $i++) {
    $buf = New-Object System.Text.StringBuilder 1024
    $mii = New-Object LiveMenu.MENUITEMINFO
    $mii.cbSize    = [System.Runtime.InteropServices.Marshal]::SizeOf($mii)
    $mii.fMask     = $MIIM_STRING -bor $MIIM_FTYPE -bor $MIIM_ID -bor $MIIM_STATE -bor $MIIM_SUBMENU -bor $MIIM_DATA
    $mii.dwTypeData = [System.Runtime.InteropServices.Marshal]::StringToHGlobalUni(''.PadRight(1024, ' '))
    $mii.cch       = 1024

    $ok = [LiveMenu.Native]::GetMenuItemInfoW($hMenu, [uint32]$i, $true, [ref]$mii)
    $text = if ($ok -and $mii.cch -gt 0) { [System.Runtime.InteropServices.Marshal]::PtrToStringUni($mii.dwTypeData, $mii.cch) } else { '' }
    [System.Runtime.InteropServices.Marshal]::FreeHGlobal($mii.dwTypeData)

    $flags = @()
    if ($mii.fType -band $MFT_OWNERDRAW) { $flags += 'OWNERDRAW' }
    if ($mii.fType -band $MFT_SEPARATOR) { $flags += 'SEP'; $seps++ }
    if ($mii.hSubMenu -ne [IntPtr]::Zero) { $flags += 'SUBMENU' }

    if ($mii.fType -band $MFT_SEPARATOR) { }
    elseif ($text) { $withText++ } else { $blank++ }

    '{0,3}  id={1,-6} cch={2,-4} data={3,-18} {4,-22} "{5}"' -f `
        $i, $mii.wID, $mii.cch, ('0x' + $mii.dwItemData.ToString('X')), ($flags -join ','), $text
}

# Where the popup actually is, versus where the pointer is and what is under it.
# A menu that receives no input may simply not be where the visible background is.
$r = New-Object LiveMenu.RECT
[void][LiveMenu.Native]::GetWindowRect($hwnd, [ref]$r)
$style   = [LiveMenu.Native]::GetWindowLongW($hwnd, -16)
$exstyle = [LiveMenu.Native]::GetWindowLongW($hwnd, -20)
Write-Host ''
Write-Host ("popup rect: ({0},{1})-({2},{3})  {4}x{5}  style=0x{6:X8} exstyle=0x{7:X8}" -f `
    $r.left, $r.top, $r.right, $r.bottom, ($r.right-$r.left), ($r.bottom-$r.top), $style, $exstyle) -ForegroundColor Green

$cur = New-Object LiveMenu.POINT
[void][LiveMenu.Native]::GetCursorPos([ref]$cur)
$under = [LiveMenu.Native]::WindowFromPoint($cur)
$sb2 = New-Object System.Text.StringBuilder 256
[void][LiveMenu.Native]::GetClassNameW($under, $sb2, 256)
Write-Host ("cursor at ({0},{1}); window under cursor = {2} class='{3}'{4}" -f `
    $cur.x, $cur.y, $under, $sb2.ToString(),
    $(if ($under -eq $hwnd) { '  <- the popup itself' } else { '  <- NOT the popup' })) -ForegroundColor Green
Write-Host ''
Write-Host "non-separator rows: $($withText + $blank)   with text: $withText   blank: $blank   separators: $seps" -ForegroundColor Cyan
Write-Host ''
if ($blank -eq 0 -and $withText -gt 0) {
    Write-Host 'VERDICT: the menu data has text. The strings exist and are correct, so the' -ForegroundColor Yellow
    Write-Host '         fault is in painting, not harvesting - DrawThemeTextEx is the only' -ForegroundColor Yellow
    Write-Host '         text call in the DLL and it is gated on _hTheme.' -ForegroundColor Yellow
}
elseif ($withText -eq 0 -and $blank -gt 0) {
    Write-Host 'VERDICT: the menu data is genuinely textless. The titles were never harvested,' -ForegroundColor Yellow
    Write-Host '         so the fault is in build_system_menuitems, not in drawing.' -ForegroundColor Yellow
}
else {
    Write-Host 'VERDICT: mixed - some rows have text and some do not. Note which ones; that' -ForegroundColor Yellow
    Write-Host '         split is the real clue.' -ForegroundColor Yellow
}
