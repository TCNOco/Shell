# svgbench

Times plutosvg rasterisation over the icons this project ships, and dumps the
pixels it produced so a library change can be checked as well as timed.

`tools/vmtest` already measures whole-menu latency, but it is the wrong
instrument for a rasteriser change: it needs a Hyper-V guest, and `BitmapCache`
rasters each icon once and reuses it, so the cost being changed is mostly
invisible to it. This runs on the host in under a second.

## Running

```bash
pwsh tools/svgbench/Export-Corpus.ps1
```

```bash
pwsh tools/svgbench/Build-Bench.ps1 -Variant old
```

```bash
tools/svgbench/bin/svgbench-old.exe --corpus tools/svgbench/corpus --reps 25 --dump tools/svgbench/out-old --json tools/svgbench/bin/result-old.json
```

`corpus/`, `bin/` and `out-*/` are generated and ignored. The corpus is derived
from `src/bin/imports/images.nss`, so re-export it after changing the icons.

## What it measures

`Export-Corpus.ps1` pulls the 100 inline SVG icons out of `images.nss` and
resolves the `@name` placeholders Shell's expression engine would normally
resolve at menu-build time, against a fixed dark palette. Fixed, because a
before/after pixel comparison is only meaningful if both sides rasterise the
same bytes.

Each icon is rendered at 16, 20, 24 and 32 px. Per icon, the fastest of N
repetitions is kept — this is a deterministic CPU-bound workload, so the fastest
run is the one least polluted by scheduling noise. `corpus` is the sum across
all 100 icons: what a cold menu costs if every icon it shows is rastered once.

`--dump` writes one `<icon>@<size>.raw` per icon: an 8-byte `int32 width,
height` header followed by tightly packed premultiplied BGRA rows. Tightly
packed rather than raw stride, so two builds stay comparable even if they pad
rows differently. The old library ships no PNG writer, which is the other reason
this is not a PNG.

## Variants

`-Variant old` links the committed `src/shared/Library/plutosvg-x64.lib`
(plutovg `c76824d`, 2022-03-30, built Jan 2023). `-Variant new` links the libs
built from the upgraded submodules. Both exes coexist so before and after can be
run back to back on one machine.

x64 only. The prebuilt x86 lib is `__stdcall` with decorated exports
(`_plutovg_create@4`), which is why `src/dll/Shell.vcxproj` compiles the whole
DLL StdCall; benchmarking it would need `/Gz` and tells you nothing extra about
rasteriser throughput.

## Baseline

`plutosvg-x64.lib` as committed, i9-13900K, Windows 11 26200, 25 reps:

| Size | Corpus (100 icons) | Per-icon median | p95 | max |
|-----:|-------------------:|----------------:|----:|----:|
| 16px |   926.6 us |  8.8 us | 15.9 us | 23.2 us |
| 20px |   988.4 us |  9.1 us | 14.8 us | 40.1 us |
| 24px |  1101.5 us | 10.4 us | 20.9 us | 27.4 us |
| 32px |  1152.6 us | 11.0 us | 20.6 us | 28.7 us |

Peak working set 5.2 MB, no render failures.

Worth reading before optimising anything: rastering *every* icon in the set at
32 px costs about 1.2 ms, and a real menu shows a fraction of them, once, behind
a cache. Raster throughput is not what makes menus feel slow. The case for
upgrading the library rests on correctness and memory safety, not on this table
— which is precisely why the table is here.
