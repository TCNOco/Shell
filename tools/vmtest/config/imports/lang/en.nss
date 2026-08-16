/*
Fallback locale for the VM smoke test.

shell.nss selects a locale with path.exists(loc_path + sys.lang + ".nss") and
falls back to this file when that misses. Install-Build.ps1 generates a file
named after the guest's own user locale containing VMTEST_LOCALE_OK, so a
correct build never reaches this value.

If the menu shows VMTEST_LOCALE_FALLBACK, locale selection is broken again:
the path.exists() call is being handed a path it cannot resolve. That is the
regression from 94d25a0, where relative paths stopped resolving against the
install folder and every non-English locale silently fell back to English.
*/

vmtest_locale="VMTEST_LOCALE_FALLBACK"
