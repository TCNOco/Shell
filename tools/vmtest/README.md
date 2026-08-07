# VM test loop

This project is a DLL injected into `explorer.exe`. A bad build means a black
desktop, and Explorer pins the DLL for as long as the extension is registered
(`DllCanUnloadNow` returns `S_FALSE`), so every iteration on a real machine
means killing the shell. Testing happens in a throwaway VM instead, from a
known-good checkpoint every time.

## What it actually checks

`Invoke-VMTest.ps1` builds, deploys, opens a **real context menu on the desktop**,
and reads the items back out of it. The assertions are:

| Check | Why it matters |
|---|---|
| `shell.dll` mapped into `explorer.exe` | The DLL was loaded at all |
| Context menu appeared | The `TrackPopupMenu` hook fired |
| Sentinel items present | The config parsed and the menu tree was built |
| `VMTEST_IMPORT_OK` present | A relative `import` resolved — the regression guarded by the `load_import` change |
| CJK and Cyrillic sentinels distinct | The ordinal comparison in `StringCompare.h` is behaving |
| Explorer survived, same pid | No crash |
| No `error` lines in `shell.log` | Nothing failed quietly |
| No new WER report for explorer.exe | No crash that got swallowed |

Menu items are read through Win32, not UI Automation. The extension owner-draws
its items but still sets `MIIM_STRING` with the title in `dwTypeData`, so
`GetMenuItemInfoW` returns real text.

## One-time VM setup

Start from any Windows 11 guest. 4 GB RAM and 2 vCPU is plenty. Generation 2
with Secure Boot on is fine — shell extensions do not require Authenticode, so
an unsigned build still loads.

From an **elevated** PowerShell on the host:

```powershell
.\Setup-TestVM.ps1 -VMName 'Windows 11 2025-10' -CreateUser
```

That script does the whole thing over PowerShell Direct: creates the test
account, enables auto-logon, sets the execution policy, disables the screen
saver and sleep timeouts, reports whether Smart App Control or Defender will
interfere, reboots, **verifies an interactive session actually came up**, then
shuts down and takes the `clean` checkpoint. Its output is transcribed to
`runs/setup.log`.

The interactive-session check is the part that matters. The smoke test drives a
real desktop, so if auto-logon silently fails every later run produces no
result at all; the setup fails loudly instead.

> Auto-logon stores the account password in plaintext under
> `HKLM\...\Winlogon`. That is how Windows auto-logon works. Only point this at
> a disposable VM with a throwaway account.

The checkpoint is restored before *and* after every run, so the guest never
accumulates state.

### Elevation

Hyper-V cmdlets need either an elevated shell or membership of the local
`Hyper-V Administrators` group. If you would rather not elevate every run:

```powershell
Add-LocalGroupMember -Group 'Hyper-V Administrators' -Member $env:USERNAME
```

That needs one sign-out to take effect. `Invoke-VMTest.ps1` checks for the
capability rather than for an elevated token, so it works either way.

## Running

```powershell
.\Invoke-VMTest.ps1 -VMName shell-test
```

Useful switches:

- `-SkipBuild` — deploy whatever is already in `src/bin`
- `-KeepRunning` — leave the VM up afterwards to poke at a failure by hand
- `-SkipConfig` — install the shipped `shell.nss` instead of the sentinel config.
  Sentinel assertions will fail; use it to eyeball the real default menu.
- `-Platform x86` — the other buildable architecture

Artifacts land in `tools/vmtest/runs/<timestamp>/result/`: the JSON result, a
screenshot of the open menu, and the guest's `shell.log`.

Exit code is 0 on pass, 1 on failure, so it drops straight into a wrapper script.

## Checking the harness itself

`Test-MenuReader.ps1` builds a popup menu in-process with the same flags the
extension uses and reads it back through the exact code path the smoke test
uses. It needs no VM and synthesises no input, so it is the fast way to tell
whether a smoke-test failure is a real regression or a broken reader:

```powershell
.\Test-MenuReader.ps1
```

## Things that cost real time getting this working

Each of these produced a failure that looked like something else entirely.

- **On Windows 11 the extension does nothing unless it is registered with
  `-treat`.** Windows 11 serves its own context menu as a WinUI XAML island,
  which never goes through `TrackPopupMenu`, so the hook has nothing to
  intercept. The extension installs, registers, loads into Explorer, and is
  invisible. `-treat` writes a `TreatAs` redirect from the modern menu's CLSID
  to this one, which is what puts the classic menu -- and therefore this
  extension -- back in the path. Diagnosed here by capturing the visible
  top-level window classes on failure and finding
  `Microsoft.UI.Content.PopupWindowSiteBridge` and
  `XamlExplorerHostIslandWindow_WASDK` where a `#32768` menu was expected.

- **PowerShell Direct usually needs the qualified `PCNAME\user` form.** The bare
  username is rejected with `The credential is invalid`, which is the same
  message you get for a wrong password, a blank password and a Microsoft
  Account. Run `whoami` inside the guest and use exactly what it prints. This
  cost six setup runs.
- **`$null` in a string P/Invoke parameter marshals as an empty string, not
  NULL.** `FindWindow(class, $null)` therefore asks for a window with an *empty
  title* and finds nothing, because the desktop is titled "Program Manager" and
  a popup menu is not empty either. Declare such parameters `IntPtr` and pass
  `[IntPtr]::Zero`, or use `[NullString]::Value`.
- **`shell.exe` is linked `SubSystem=Windows`.** The call operator does not wait
  for a GUI-subsystem binary and never sets `$LASTEXITCODE`, so registration
  races whatever checks follow it, and `Set-StrictMode` turns the unset variable
  into a terminating error. Use `Start-Process -PassThru` plus `WaitForExit`.
- **`shell.exe -register` exits 1 even when it succeeds.** Verify the CLSID in
  the registry instead of trusting the exit code.
- **Never launch Explorer from a PowerShell Direct session.** That session is not
  interactive, so the new shell lands in the wrong session, the real desktop
  stays without one, and the smoke test inspects a stray process. Windows
  restarts the shell itself through `AutoRestartShell`.
- **Identify Explorer with `GetShellWindow()`**, not by picking the oldest
  `explorer.exe`. Only one instance owns the desktop, and checking a different
  one reports the DLL as missing when it is loaded correctly.
- **`$PSScriptRoot` is empty under `Start-Process -Verb RunAs`**, which routes
  through ShellExecute. It is populated normally otherwise, including in a
  `param()` default. Fall back to `$MyInvocation.MyCommand.Path`.
- **Explorer can take ~55s** to restart and map the DLL after registration.
  Wait for the module to appear rather than sleeping a fixed interval.

## Gotchas worth knowing

- **`Invoke-SmokeTest.ps1` and `config/shell.nss` must keep their UTF-8 BOM.**
  Windows PowerShell 5.1 reads a BOM-less `.ps1` as ANSI, and the shell
  extension's own encoding detection (`Encoding::GetType`) only recognises UTF-8
  when a BOM is present. Either one silently mangles the non-ASCII sentinels
  into something no assertion can match. `.gitattributes` pins the encoding.
- **PowerShell Direct sessions are not interactive.** They cannot see the
  desktop, which is why the smoke test is launched as a scheduled task running
  as the logged-on user rather than invoked directly.
- **The guest needs no network.** Everything goes over PowerShell Direct.
- The run prompts once for guest credentials. Wrap it with a stored
  `PSCredential` if you are running it repeatedly.
