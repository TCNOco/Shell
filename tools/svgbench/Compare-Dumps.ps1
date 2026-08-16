# Compares two svgbench --dump directories pixel by pixel.
#
#   pwsh tools/svgbench/Compare-Dumps.ps1 -Old tools/svgbench/out-old -New tools/svgbench/out-new
#
# Some difference is expected and wanted: the newer plutovg rounds float-to-fixed
# rather than truncating (6987abc) and expands clip bounds by a pixel to cover
# rendering overshoot (cd567f6), both of which change edge antialiasing. What
# this is looking for is the difference that is not that -- an icon that lost a
# shape, changed colour, or came out empty.
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Old,
    [Parameter(Mandatory)] [string] $New,
    # Icons whose mean absolute difference exceeds this are listed individually.
    [double] $ReportThreshold = 1.0,
    [int]    $Top = 15
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Read-Dump {
    param([string] $Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 8) { return $null }
    [pscustomobject]@{
        Width  = [BitConverter]::ToInt32($bytes, 0)
        Height = [BitConverter]::ToInt32($bytes, 4)
        Pixels = $bytes
    }
}

$oldFiles = Get-ChildItem -LiteralPath $Old -Filter *.raw | Sort-Object Name
if ($oldFiles.Count -eq 0) { throw "no .raw dumps in $Old" }

$results = [System.Collections.Generic.List[object]]::new()
$missing = @()

foreach ($f in $oldFiles) {
    $newPath = Join-Path $New $f.Name
    if (-not (Test-Path -LiteralPath $newPath)) { $missing += $f.Name; continue }

    $a = Read-Dump $f.FullName
    $b = Read-Dump $newPath
    if (-not $a -or -not $b) { $missing += $f.Name; continue }

    if ($a.Width -ne $b.Width -or $a.Height -ne $b.Height) {
        $results.Add([pscustomobject]@{
            Name = $f.Name; Mean = [double]::PositiveInfinity; Max = 255
            DiffPct = 100.0; Note = "size $($a.Width)x$($a.Height) -> $($b.Width)x$($b.Height)"
        })
        continue
    }

    $n = $a.Pixels.Length
    if ($b.Pixels.Length -ne $n) { $missing += $f.Name; continue }

    [long] $sum = 0
    [int]  $max = 0
    [long] $differing = 0
    for ($i = 8; $i -lt $n; $i++) {
        $d = [Math]::Abs([int]$a.Pixels[$i] - [int]$b.Pixels[$i])
        if ($d -ne 0) {
            $sum += $d
            $differing++
            if ($d -gt $max) { $max = $d }
        }
    }
    $count = $n - 8
    $results.Add([pscustomobject]@{
        Name    = $f.Name
        Mean    = if ($count -gt 0) { $sum / $count } else { 0.0 }
        Max     = $max
        DiffPct = if ($count -gt 0) { 100.0 * $differing / $count } else { 0.0 }
        Note    = ''
    })
}

$identical = @($results | Where-Object { $_.Max -eq 0 }).Count
$changed   = $results.Count - $identical

Write-Host ""
Write-Host "compared $($results.Count) dumps: $identical byte-identical, $changed differing"
if ($missing.Count -gt 0) {
    Write-Warning "$($missing.Count) present in old but not new (render failure?): $($missing[0..([Math]::Min(9,$missing.Count-1))] -join ', ')"
}

$notable = @($results | Where-Object { $_.Mean -gt $ReportThreshold } | Sort-Object Mean -Descending)
if ($notable.Count -gt 0) {
    Write-Host ""
    Write-Host "mean absolute difference over $ReportThreshold (of 255), worst ${Top}:"
    $notable | Select-Object -First $Top | ForEach-Object {
        Write-Host ("  {0,-44} mean {1,6:N2}  max {2,3}  pixels {3,5:N1}%  {4}" -f `
            $_.Name, $_.Mean, $_.Max, $_.DiffPct, $_.Note)
    }
} else {
    Write-Host "no icon differs by more than $ReportThreshold mean"
}

$all = @($results | Where-Object { $_.Max -gt 0 })
if ($all.Count -gt 0) {
    $means = @($all | ForEach-Object { $_.Mean }) | Sort-Object
    Write-Host ""
    Write-Host ("across the {0} that differ: mean {1:N2}, median {2:N2}, worst {3:N2}, worst single channel {4}" -f `
        $all.Count,
        (($all | Measure-Object Mean -Average).Average),
        $means[[int]($means.Count / 2)],
        (($all | Measure-Object Mean -Maximum).Maximum),
        (($all | Measure-Object Max -Maximum).Maximum))
}

if ($missing.Count -gt 0) { exit 1 }
