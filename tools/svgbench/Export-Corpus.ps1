# Extracts the inline SVG icons from src/bin/imports/images.nss into standalone
# .svg files, so the rasteriser can be benchmarked against the artwork this
# project actually ships rather than a synthetic corpus.
#
# images.nss is config, not SVG: icons are single-quoted values that reference
# each other and the active theme through @name placeholders. Shell's expression
# engine resolves those at menu-build time, before the string reaches plutosvg.
# This script does the same substitution with a fixed palette, so the corpus is
# deterministic and a before/after pixel comparison means something.
#
#   pwsh tools/svgbench/Export-Corpus.ps1
#
[CmdletBinding()]
param(
    [string] $Source = (Join-Path $PSScriptRoot '..\..\src\bin\imports\images.nss'),
    [string] $OutDir = (Join-Path $PSScriptRoot 'corpus'),

    # Dark theme. The two conditionals at the top of images.nss resolve to these
    # when theme.islight is false; color1/color2 are stand-ins for the theme's
    # own values, fixed here only so both sides of a comparison rasterise the
    # same bytes. Their exact hue does not affect raster cost.
    [string] $Color1 = '#e0e0e0',
    [string] $Color2 = '#4cc2ff',
    [string] $Color3 = 'none',
    [string] $ColorIsLightWB = '#000'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not (Test-Path -LiteralPath $Source)) { throw "source not found: $Source" }
$text = Get-Content -LiteralPath $Source -Raw

# Definitions always start at column 0 as `@name='...'` or `$name='...'`, and
# bodies may contain single quotes of their own inside @if(...) expressions.
# Splitting on the definition start and taking first-quote..last-quote is
# therefore more reliable than trying to match the closing quote directly.
# The name list may carry quoted, non-ASCII aliases (@select_all, 'Выбрать все'),
# so anything up to the assignment counts as the name. Anchoring at column 0 and
# requiring =' keeps this from matching @references inside an indented body.
$starts = [regex]::Matches($text, "(?m)^[@`$][^=\r\n]{0,160}=\s*'")
if ($starts.Count -eq 0) { throw "no definitions found in $Source" }

$defs = [ordered]@{}
$order = @()

for ($i = 0; $i -lt $starts.Count; $i++) {
    $begin = $starts[$i].Index
    $end   = if ($i + 1 -lt $starts.Count) { $starts[$i + 1].Index } else { $text.Length }
    $chunk = $text.Substring($begin, $end - $begin)

    $eq = $chunk.IndexOf('=')
    $names = $chunk.Substring(1, $eq - 1).Trim()

    $first = $chunk.IndexOf("'")
    $last  = $chunk.LastIndexOf("'")
    if ($last -le $first) { continue }
    $body = $chunk.Substring($first + 1, $last - $first - 1)

    # `@copy,copy_to_clipboard=` defines one icon under several names. Only the
    # first is needed for a corpus; the aliases are the same bytes.
    $name = ($names -split ',')[0].Trim().Trim("'")
    if (-not $name) { continue }
    $defs[$name] = $body
    $order += $name
}

Write-Host "parsed $($defs.Count) definitions from $(Split-Path -Leaf $Source)"

function Resolve-Palette {
    param([string] $s)
    # Some icons carry the light/dark conditional inline rather than via the
    # two variables at the top of the file. Only theme.islight is ever tested,
    # and this corpus fixes it to false, so the else-branch always wins.
    $s = [regex]::Replace($s, "@if\(\s*theme\.islight\s*,\s*(?:'[^']*'|[^,)]*)\s*,\s*(?<else>'[^']*'|[^,)]*)\s*\)", {
        param($m)
        $m.Groups['else'].Value.Trim().Trim("'")
    })
    $s = $s -replace '@image\.color1', $Color1
    $s = $s -replace '@image\.color2', $Color2
    $s = $s -replace '@image\.color3', $Color1
    $s = $s -replace '@color_islight_WB', $ColorIsLightWB
    $s = $s -replace '@color3', $Color3
    return $s
}

# Every body is made palette-clean before any of them is spliced into another.
# Doing it the other way round leaves placeholders inside a referenced icon
# unresolved, because substitution would already have run on the referrer.
foreach ($k in @($defs.Keys)) { $defs[$k] = Resolve-Palette $defs[$k] }

# Icons reference shared fragments (@clipPath, @svg_window_template) and
# occasionally each other. Bounded rather than recursive: a self-referencing
# definition in config should not hang the extractor.
function Resolve-Refs {
    param([string] $s)
    for ($depth = 0; $depth -lt 8; $depth++) {
        $before = $s
        $s = [regex]::Replace($s, '@([A-Za-z_][A-Za-z0-9_]*)', {
            param($m)
            $key = $m.Groups[1].Value
            if ($defs.Contains($key)) { return $defs[$key] }
            return $m.Value
        })
        if ($s -eq $before) { break }
    }
    return $s
}

if (Test-Path -LiteralPath $OutDir) { Remove-Item -LiteralPath $OutDir -Recurse -Force }
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

$written = 0
$skipped = 0
$unresolved = @()

foreach ($name in $order) {
    $body = Resolve-Refs $defs[$name]

    # Fragments such as $clipPath and $svg_window_template are path snippets
    # meant to be spliced into an icon, not documents in their own right.
    if ($body -notmatch '<svg') { $skipped++; continue }

    # An @if() that survived means the expression engine, not simple
    # substitution, was needed. Record it rather than emitting broken markup.
    if ($body -match '@[A-Za-z_]') {
        $unresolved += $name
        continue
    }

    $safe = $name -replace '[^A-Za-z0-9_.-]', '_'
    Set-Content -LiteralPath (Join-Path $OutDir "$safe.svg") -Value $body -Encoding UTF8 -NoNewline
    $written++
}

Write-Host "wrote $written svg files to $OutDir ($skipped fragments skipped)"
if ($unresolved.Count -gt 0) {
    Write-Warning "$($unresolved.Count) left unresolved: $($unresolved -join ', ')"
}
if ($written -eq 0) { throw 'no svg files written' }
