[![Ceasefire Now](https://badge.techforpalestine.org/default)](https://techforpalestine.org/learn-more)

[![Build](../../actions/workflows/build.yml/badge.svg)](../../actions/workflows/build.yml)
[![Nightly](https://img.shields.io/badge/Nightly-nightly.link-purple)](https://nightly.link/moudey/Shell/workflows/build/main)

# [Shell](https://nilesoft.org)
Powerful manager for Windows File Explorer context menu.
<br>

<p align="center">
 <img src="https://www.nilesoft.org/images/logo-256.png">
 <br>
 <br>
</p>

Building
------------------
Needs Visual Studio 2022 Build Tools with the **Desktop development with C++**
workload (the v143 toolset). Nothing has to be on PATH, and `nuget.exe` is not
required — MSBuild does both restores.

```powershell
.\build.ps1                        # x64 release; -Platform x86|ARM64, -Rebuild
.\tools\install-local.ps1          # elevated; installs and registers the build
.\tools\install-local.ps1 -Uninstall
```

The restore step is not optional. VC-LTL arrives via a `packages.config`, which
a plain `-t:Restore` skips, and `VC-LTL.props` imports it only `Condition="Exists(...)"` —
so without it the build quietly links the static MSVC CRT instead of importing
`msvcrt.dll`, giving a ~194 KB larger binary with a different heap than CI ships.
That used to happen silently; the build now stops and says so. `build.ps1`
restores correctly, and to build without VC-LTL on purpose pass
`-p:ShellAllowNoVCLTL=true`.

`install-local.ps1` refuses to run while another Shell build is registered —
this fork has its own CLSIDs, so both can register at once and both would then
hook `TrackPopupMenu`. It also preserves an existing `shell.nss` across
reinstalls unless you pass `-ResetConfig`.

## Details
<p>
Shell is a context menu extender that lets you handpick the items to integrate into the Windows File Explorer context menu, create custom commands to access all your favorite web pages, files, and folders, and launch any application directly from the context menu.<br>
It also provides you a convenient solution to modify or remove any context menu item added by the system or third-party software.
</p>

Features
------------------
* Lightweight, portable, and relatively easy to use.
* Fully customize the appearance.
* Adding new custom items such as (sub-menu, menu-items, and separator).
* Modify or remove items that already exist.
* Support all file system objects, including files, folders, desktop, and the taskbar.
* Support expressions syntax. with built-in functions and predefined variables.
* Support colors, glyphs, SVG, embedded icons, and image files such as .ico, .png or .bmp.
* Support search and filter.
* Support for complex nested menus.
* Support multiple columns.
* Quickly and easily configure file in plain text.
* Minimal resource usage.
* No limitations.


Requirements
------------------
  * Microsoft Windows 7/8/10/11 


Documentation
------------------
Browse the [online documentation here.](https://nilesoft.org/docs)

[<img src="https://devin.ai/assets/deepwiki-badge.png" alt="Ask DeepWiki.com" height="20"/>](https://deepwiki.com/moudey/Shell)

Download
------------------
Download the latest version:  
https://nilesoft.org/download

Screenshots
------------------
<p align="center">
<img src="/screenshots/folder-back.png"><img src="/screenshots/file-manage.png"><br>
<img src="/screenshots/view.png"><img src="/screenshots/edit.png"><br>
<img src="/screenshots/terminal.png"><img src="/screenshots/taskbar.png"><br>
<img src="/screenshots/goto2.png"><img src="/screenshots/gradient.png"><br>
<img src="/screenshots/acrylic.png"><br>

<br>
<br>
</p>

Donate
------------------
If you really love Shell and would like to see it continue to improve.

[![Paypal](https://img.shields.io/badge/Donate-PayPal-blue.svg)](https://www.paypal.me/nilesoft)
[![BuyMeACoffee](https://img.shields.io/badge/Donate-BuyMeACoffee-yellow.svg)](https://www.buymeacoffee.com/moudey)


