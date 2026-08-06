# Validates the MENUITEMINFO marshalling and Get-MenuItems logic used by
# Invoke-SmokeTest.ps1, without needing a VM or synthesising any input.
#
# Builds a popup menu in-process with the same flags the shell extension uses
# (MFT_OWNERDRAW together with MIIM_STRING) and reads it back through the exact
# code path the smoke test uses.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Add-Type -Namespace VmTest -Name Native -UsingNamespace System.Text -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)]
public struct MENUITEMINFO {
    public int cbSize, fMask, fType, fState, wID;
    public IntPtr hSubMenu, hbmpChecked, hbmpUnchecked;
    public IntPtr dwItemData;
    public IntPtr dwTypeData;
    public int cch;
    public IntPtr hbmpItem;
}
[DllImport("user32.dll")] public static extern IntPtr CreatePopupMenu();
[DllImport("user32.dll")] public static extern bool DestroyMenu(IntPtr h);
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern bool InsertMenuItemW(IntPtr hMenu, uint item, bool byPos, ref MENUITEMINFO mii);
[DllImport("user32.dll")] public static extern int GetMenuItemCount(IntPtr hMenu);
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern bool GetMenuItemInfoW(IntPtr hMenu, uint item, bool byPos, ref MENUITEMINFO mii);

public const uint MIIM_STRING   = 0x00000040;
public const uint MIIM_SUBMENU  = 0x00000004;
public const uint MIIM_FTYPE    = 0x00000100;
public const uint MIIM_ID       = 0x00000002;
public const uint MFT_SEPARATOR = 0x00000800;
public const uint MFT_OWNERDRAW = 0x00000100;
'@

# --- verbatim from Invoke-SmokeTest.ps1 -------------------------------------
function Get-MenuItems {
    param([IntPtr] $HMenu, [int] $Depth = 0)

    $items = @()
    if ($HMenu -eq [IntPtr]::Zero) { return $items }

    $count = [VmTest.Native]::GetMenuItemCount($HMenu)
    for ($i = 0; $i -lt $count; $i++) {
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
                    index = $i; depth = $Depth; text = $text
                    separator = $isSep; hasSub = ($mii.hSubMenu -ne [IntPtr]::Zero)
                }
                if ($mii.hSubMenu -ne [IntPtr]::Zero -and $Depth -lt 1) {
                    $items += Get-MenuItems -HMenu $mii.hSubMenu -Depth ($Depth + 1)
                }
            }
        }
        finally { [System.Runtime.InteropServices.Marshal]::FreeHGlobal($ptr) }
    }
    return $items
}
# ----------------------------------------------------------------------------

function New-Item2 {
    param([IntPtr] $HMenu, [uint32] $Pos, [string] $Text, [int] $Id,
          [switch] $Separator, [IntPtr] $Sub = [IntPtr]::Zero)

    $mii = New-Object VmTest.Native+MENUITEMINFO
    $mii.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf($mii)
    $strPtr = [IntPtr]::Zero

    if ($Separator) {
        $mii.fMask = [int]([VmTest.Native]::MIIM_FTYPE)
        $mii.fType = [int][VmTest.Native]::MFT_SEPARATOR
    }
    else {
        # Exactly what the extension does: owner-drawn, but the title is still
        # supplied via MIIM_STRING, which is what makes it readable at all.
        $mii.fMask = [int]([VmTest.Native]::MIIM_STRING -bor [VmTest.Native]::MIIM_FTYPE -bor [VmTest.Native]::MIIM_ID)
        $mii.fType = [int][VmTest.Native]::MFT_OWNERDRAW
        $mii.wID = $Id
        $strPtr = [System.Runtime.InteropServices.Marshal]::StringToHGlobalUni($Text)
        $mii.dwTypeData = $strPtr
        $mii.cch = $Text.Length
    }
    if ($Sub -ne [IntPtr]::Zero) {
        $mii.fMask = $mii.fMask -bor [int][VmTest.Native]::MIIM_SUBMENU
        $mii.hSubMenu = $Sub
    }
    $ok = [VmTest.Native]::InsertMenuItemW($HMenu, $Pos, $true, [ref]$mii)
    if (-not $ok) { throw "InsertMenuItemW failed for '$Text'" }
}

$expected = @(
    'VMTEST_SENTINEL_ROOT',
    'VMTEST_ASCII',
    ('VMTEST_CJK_' + [char]0x4E2D),   # 中
    ('VMTEST_CJK_' + [char]0x6E2D),   # 渭
    ('VMTEST_CYR_' + [char]0x0410),   # А
    ('VMTEST_CYR_' + [char]0x0430),   # а
    'VMTEST_IMPORT_OK'
)

$sub = [VmTest.Native]::CreatePopupMenu()
$menu = [VmTest.Native]::CreatePopupMenu()
$fails = 0
try {
    $i = 0
    foreach ($t in $expected[1..($expected.Count - 1)]) {
        New-Item2 -HMenu $sub -Pos ([uint32]$i) -Text $t -Id (100 + $i); $i++
    }
    New-Item2 -HMenu $menu -Pos 0 -Text $expected[0] -Id 1
    New-Item2 -HMenu $menu -Pos 1 -Separator
    New-Item2 -HMenu $menu -Pos 2 -Text 'VMTEST_SENTINEL_MENU' -Id 2 -Sub $sub

    $items = @(Get-MenuItems -HMenu $menu)
    $all = @($items | ForEach-Object { $_.text })

    Write-Host ("struct size: {0} bytes (want 80 on x64)" -f `
        [System.Runtime.InteropServices.Marshal]::SizeOf((New-Object VmTest.Native+MENUITEMINFO)))
    Write-Host ("read back {0} entries" -f $items.Count)
    Write-Host ''

    foreach ($t in @($expected + 'VMTEST_SENTINEL_MENU')) {
        $ok = $all -contains $t
        if (-not $ok) { $fails++ }
        Write-Host ("{0} round-trip '{1}'" -f $(if ($ok) { '  ok  ' } else { ' FAIL ' }), $t)
    }

    $sepCount = @($items | Where-Object { $_.separator }).Count
    $ok = ($sepCount -eq 1); if (-not $ok) { $fails++ }
    Write-Host ("{0} separator detected ({1})" -f $(if ($ok) { '  ok  ' } else { ' FAIL ' }), $sepCount)

    $subCount = @($items | Where-Object { $_.depth -eq 1 }).Count
    $ok = ($subCount -eq 6); if (-not $ok) { $fails++ }
    Write-Host ("{0} submenu recursion ({1} children, want 6)" -f $(if ($ok) { '  ok  ' } else { ' FAIL ' }), $subCount)

    # The CJK pair must survive as two distinct strings; collapsing them would
    # mean the reader, not the extension, is losing the distinction.
    $ok = ($all -contains $expected[2]) -and ($all -contains $expected[3]) -and ($expected[2] -ne $expected[3])
    if (-not $ok) { $fails++ }
    Write-Host ("{0} CJK pair kept distinct through marshalling" -f $(if ($ok) { '  ok  ' } else { ' FAIL ' }))
}
finally {
    [void][VmTest.Native]::DestroyMenu($menu)
}

Write-Host ''
Write-Host ("{0}: {1} failure(s)" -f $(if ($fails -eq 0) { 'PASS' } else { 'FAIL' }), $fails)
exit $fails
