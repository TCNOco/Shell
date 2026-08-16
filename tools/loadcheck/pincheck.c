// Does shell.dll survive FreeLibrary?
//
// It has to. The DLL patches import tables in other modules, and nothing takes
// those patches back out, so if the image is ever unmapped the next call
// through a patched entry jumps into freed memory. That is not hypothetical:
// Explorer's shell-extension host caches handler DLLs and calls FreeLibrary on
// them when it decides they are idle, which unloaded a registered build a few
// minutes after every start and faulted explorer.exe at 0xc0000005 inside
// "shell.dll_unloaded" on a thirty-one second cycle.
//
// Answering S_FALSE from DllCanUnloadNow does not cover this - COM asks,
// Explorer does not - so the DLL pins itself with GET_MODULE_HANDLE_EX_FLAG_PIN
// when it installs the first hook. This checks that the pin actually took.
//
//   cl /nologo /O2 /W3 pincheck.c /Fe:pincheck.exe
//   pincheck.exe <path-to-shell.dll>

#include <windows.h>
#include <stdio.h>

int wmain(int argc, wchar_t **argv)
{
    const wchar_t *path = (argc > 1) ? argv[1] : L"shell.dll";
    HMODULE mod, probe;
    int i;

    mod = LoadLibraryW(path);
    if (!mod) {
        wprintf(L"FAIL  LoadLibrary(%s) -> %lu\n", path, GetLastError());
        return 2;
    }
    wprintf(L"loaded at %p\n", (void *)mod);

    // One FreeLibrary per LoadLibrary. Without a pin this drops the count to
    // zero and unmaps the image.
    if (!FreeLibrary(mod))
        wprintf(L"note  FreeLibrary returned FALSE (%lu)\n", GetLastError());

    probe = GetModuleHandleW(L"shell.dll");
    if (probe) {
        wprintf(L"PASS  still mapped at %p after FreeLibrary - pin holds\n", (void *)probe);
    } else {
        wprintf(L"FAIL  unmapped after one FreeLibrary - the pin did not take,\n");
        wprintf(L"      so any host can unload this DLL and leave its hooks dangling\n");
        return 1;
    }

    // Lean on it: a caching host may free more than once over a session.
    for (i = 0; i < 8; i++)
        FreeLibrary(mod);

    probe = GetModuleHandleW(L"shell.dll");
    if (!probe) {
        wprintf(L"FAIL  unmapped after repeated FreeLibrary calls\n");
        return 1;
    }
    wprintf(L"PASS  survived 8 further FreeLibrary calls\n");
    return 0;
}
