// Guards the DLL entry point against work that must not happen under the
// loader lock.
//
// shell.dll is mapped into every process that shows a context menu, so DllMain
// runs constantly and in hosts we do not control. It used to call
// CoInitializeEx and activate CLSID_GlobalOptions from DLL_PROCESS_ATTACH;
// both are COM calls under the loader lock, which Microsoft documents as
// unsupported and which deadlock in the wrong circumstances.
//
// The oracle is CoInitializeEx's own return value. On a thread with no
// apartment it returns S_OK; on one that already has a matching apartment it
// returns S_FALSE. Loading the DLL on a deliberately COM-free thread and then
// asking therefore tells us whether DllMain got there first.
//
// Verified to detect the regression: built against the commit that still had
// the CoInitializeEx in DllMain, this reports S_FALSE and exits non-zero.
//
//   cl /O2 loadcheck.c ole32.lib
//   loadcheck path\to\shell.dll

#include <stdio.h>
#include <windows.h>
#include <objbase.h>

static const char *hr_name(HRESULT hr)
{
    switch(hr)
    {
        case S_OK:               return "S_OK (no apartment existed)";
        case S_FALSE:            return "S_FALSE (an apartment already existed)";
        case RPC_E_CHANGED_MODE: return "RPC_E_CHANGED_MODE (already MTA)";
        default:                 return "unexpected";
    }
}

int main(int argc, char **argv)
{
    const char *dll = argc > 1 ? argv[1] : "shell.dll";
    int failures = 0;

    printf("loadcheck: %s\n", dll);

    // Deliberately no CoInitializeEx before the load.
    DWORD t0 = GetTickCount();
    HMODULE h = LoadLibraryA(dll);
    DWORD elapsed = GetTickCount() - t0;

    if(!h)
    {
        printf("  FAIL LoadLibrary failed, error %lu\n", GetLastError());
        return 1;
    }
    printf("  ok   DllMain returned (%lu ms)\n", elapsed);

    HRESULT hr = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
    printf("  %s COM untouched by DllMain -> %s\n",
           hr == S_OK ? "ok  " : "FAIL", hr_name(hr));
    if(hr != S_OK)
    {
        printf("        DllMain initialised COM on the loading thread. That is a\n"
               "        loader-lock hazard; do it on the thread that needs it.\n");
        failures++;
    }
    if(SUCCEEDED(hr))
        CoUninitialize();

    // Exported so the COM registration can map the DLL; it intentionally
    // returns E_NOTIMPL. Its presence confirms the module initialised.
    if(!GetProcAddress(h, "DllGetClassObject"))
    {
        printf("  FAIL DllGetClassObject not exported\n");
        failures++;
    }
    else
        printf("  ok   DllGetClassObject exported\n");

    FreeLibrary(h);
    printf("  ok   FreeLibrary returned\n");

    printf("%s: %d failure(s)\n", failures ? "FAIL" : "PASS", failures);
    return failures;
}
