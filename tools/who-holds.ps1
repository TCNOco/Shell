#Requires -Version 5.1
<#
.SYNOPSIS
    Name the processes holding a real file handle on a path - the ones that
    block a rename - and optionally close those handles.

.DESCRIPTION
    Restart Manager lists everyone who has a file mapped OR open, which for
    shell.dll is every process that ever raised a menu (dozens), and a mapped
    image does not block a rename anyway. What blocks it is a plain handle opened
    without FILE_SHARE_DELETE, and only the kernel handle table says who has one.

    Walks SystemExtendedHandleInformation, duplicates each file handle into this
    process, resolves its path, and reports the matches. Needs elevation to see
    into other users' and services' processes; without it, only this user's.

    -Close duplicates each matching handle with DUPLICATE_CLOSE_SOURCE, which
    closes it in the owning process. That is what Sysinternals handle -c does.
    Safe for a reader (a scanner, an indexer, an appraisal service); a process
    that was mid-write would lose its handle. Used by install-local.ps1 when the
    rename of an in-use shell.dll keeps failing, so a stuck install does not end
    in "reboot and try again".

.PARAMETER Path
    The file to look for.

.PARAMETER Close
    Close the matching handles in their owning processes.

.EXAMPLE
    tools\who-holds.ps1 'C:\Program Files\TCNO Nilesoft Shell\shell.dll'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Path,
    [switch] $Close
)

if (-not ('HandleHunt.Native' -as [type])) {
    $src = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
namespace HandleHunt {
  public class Holder { public int Pid; public ulong Handle; public string Path; }
  public static class Native {
    [StructLayout(LayoutKind.Sequential)]
    struct ENTRY { public IntPtr Object; public UIntPtr Pid; public UIntPtr Handle; public uint Access; public ushort BackTrace; public ushort TypeIndex; public uint Attrs; public uint Reserved; }
    [DllImport("ntdll.dll")] static extern int NtQuerySystemInformation(int cls, IntPtr buf, int len, out int ret);
    [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool DuplicateHandle(IntPtr srcProc, IntPtr src, IntPtr dstProc, out IntPtr dst, uint access, bool inherit, uint options);
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll")] static extern int GetCurrentProcessId();
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll")] static extern uint GetFileType(IntPtr h);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern uint GetFinalPathNameByHandleW(IntPtr h, StringBuilder buf, uint len, uint flags);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr CreateFileW(string name, uint access, uint share, IntPtr sa, uint disp, uint flags, IntPtr tmpl);

    const int SystemExtendedHandleInformation = 64;
    const uint PROCESS_DUP_HANDLE = 0x0040;
    const uint DUPLICATE_SAME_ACCESS = 0x2, DUPLICATE_CLOSE_SOURCE = 0x1;
    const uint FILE_TYPE_DISK = 1;

    static ENTRY[] Snapshot() {
      int len = 1 << 20;
      for (;;) {
        IntPtr buf = Marshal.AllocHGlobal(len);
        try {
          int ret;
          int st = NtQuerySystemInformation(SystemExtendedHandleInformation, buf, len, out ret);
          if (st == unchecked((int)0xC0000004)) { len = Math.Max(len * 2, ret + 65536); continue; }
          if (st != 0) throw new Exception("NtQuerySystemInformation " + st.ToString("X8"));
          long count = (long)(ulong)Marshal.ReadIntPtr(buf);
          int esz = Marshal.SizeOf(typeof(ENTRY));
          long first = (long)buf + IntPtr.Size * 2;
          var arr = new ENTRY[count];
          for (long i = 0; i < count; i++)
            arr[i] = (ENTRY)Marshal.PtrToStructure(new IntPtr(first + i * esz), typeof(ENTRY));
          return arr;
        } finally { Marshal.FreeHGlobal(buf); }
      }
    }

    // The type index for "File" is not fixed across Windows versions; read it
    // off a file handle of our own. The probe must be open BEFORE the snapshot
    // is taken, or it is not in it.
    static ENTRY[] SnapshotWithFileType(string probe, out ushort fileType) {
      IntPtr h = CreateFileW(probe, 0x80000000, 7, IntPtr.Zero, 3, 0x80, IntPtr.Zero);
      if (h == new IntPtr(-1)) throw new Exception("cannot open probe file " + probe);
      try {
        var all = Snapshot();
        int me = GetCurrentProcessId();
        foreach (var e in all)
          if ((int)(ulong)e.Pid == me && (long)(ulong)e.Handle == (long)h) { fileType = e.TypeIndex; return all; }
        throw new Exception("probe handle not found in the snapshot");
      } finally { CloseHandle(h); }
    }

    static string Norm(string p) {
      if (p.StartsWith(@"\\?\UNC\")) return @"\\" + p.Substring(8);
      if (p.StartsWith(@"\\?\")) return p.Substring(4);
      return p;
    }

    public static List<Holder> Find(string target, bool close) {
      ushort fileType;
      var all = SnapshotWithFileType(target, out fileType);
      string want = Norm(target).ToLowerInvariant();
      var found = new List<Holder>();
      var procs = new Dictionary<int, IntPtr>();
      int me = GetCurrentProcessId();
      var sb = new StringBuilder(1024);
      try {
        foreach (var e in all) {
          if (e.TypeIndex != fileType) continue;
          int pid = (int)(ulong)e.Pid;
          if (pid == me || pid <= 4) continue;
          IntPtr ph;
          if (!procs.TryGetValue(pid, out ph)) { ph = OpenProcess(PROCESS_DUP_HANDLE, false, pid); procs[pid] = ph; }
          if (ph == IntPtr.Zero) continue;
          IntPtr dup;
          if (!DuplicateHandle(ph, new IntPtr((long)(ulong)e.Handle), GetCurrentProcess(), out dup, 0, false, DUPLICATE_SAME_ACCESS)) continue;
          try {
            // Only disk files get a name query: that is the call that can hang
            // on a synchronous pipe, and GetFileType is cheap and does not.
            if (GetFileType(dup) != FILE_TYPE_DISK) continue;
            sb.Length = 0;
            uint n = GetFinalPathNameByHandleW(dup, sb, (uint)sb.Capacity, 0);
            if (n == 0 || n >= sb.Capacity) continue;
            string p = Norm(sb.ToString());
            if (!string.Equals(p.ToLowerInvariant(), want)) continue;
            found.Add(new Holder { Pid = pid, Handle = (ulong)e.Handle, Path = p });
            if (close) {
              IntPtr d2;
              if (DuplicateHandle(ph, new IntPtr((long)(ulong)e.Handle), GetCurrentProcess(), out d2, 0, false, DUPLICATE_CLOSE_SOURCE))
                CloseHandle(d2);
            }
          } finally { CloseHandle(dup); }
        }
      } finally {
        foreach (var kv in procs) if (kv.Value != IntPtr.Zero) CloseHandle(kv.Value);
      }
      return found;
    }
  }
}
'@
    $savedLib = $env:LIB; $savedInc = $env:INCLUDE
    try { $env:LIB = ''; $env:INCLUDE = ''; Add-Type -TypeDefinition $src -ErrorAction Stop }
    finally { $env:LIB = $savedLib; $env:INCLUDE = $savedInc }
}

$full = (Resolve-Path -LiteralPath $Path).ProviderPath
$holders = [HandleHunt.Native]::Find($full, [bool]$Close)

if (-not $holders -or $holders.Count -eq 0) {
    Write-Host "no process holds a file handle on $full" -ForegroundColor Green
    Write-Host '(mapped-image references do not count; they do not block a rename)' -ForegroundColor DarkGray
    return
}

foreach ($h in $holders) {
    $p = Get-Process -Id $h.Pid -ErrorAction SilentlyContinue
    $name = if ($p) { $p.ProcessName } else { '?' }
    $svc = Get-CimInstance Win32_Service -Filter "ProcessId = $($h.Pid)" -ErrorAction SilentlyContinue |
           Select-Object -ExpandProperty Name -ErrorAction SilentlyContinue
    $tag = if ($svc) { "  service: $($svc -join ',')" } else { '' }
    $what = if ($Close) { 'CLOSED handle' } else { 'handle' }
    Write-Host ("{0} 0x{1:X} in {2} (pid {3}){4}" -f $what, $h.Handle, $name, $h.Pid, $tag) -ForegroundColor Yellow
}
