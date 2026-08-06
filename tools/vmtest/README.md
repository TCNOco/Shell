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

You need Hyper-V and an elevated shell on the host.

1. Create a Windows 11 VM. 4 GB RAM and 2 vCPU is plenty. Generation 2, Secure
   Boot on — the extension is unsigned but shell extensions do not require
   Authenticode, so this still loads.
2. Inside the guest:
   - Create a local user (default assumed here: `tester`) and make it an admin.
   - **Enable auto-logon** for that user. The smoke test drives a real desktop,
     so a user must be logged in and a session must exist. Without this the run
     produces no `result.json`.
   - `Set-ExecutionPolicy -Scope LocalMachine RemoteSigned`
   - Turn off anything that would interfere with a synthesised right-click:
     screen saver, lock screen timeout, sleep.
3. Shut the guest down cleanly, then from the host:

   ```powershell
   Checkpoint-VM -Name shell-test -SnapshotName clean
   ```

The checkpoint is restored before *and* after every run, so the guest never
accumulates state between runs.

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
