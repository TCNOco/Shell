// Test configuration for the VM smoke test.
//
// The sentinel titles below are what Invoke-SmokeTest.ps1 asserts on. Their
// presence in a real popup menu proves the whole chain worked: the DLL was
// loaded into explorer.exe, it hooked TrackPopupMenu, it found and parsed this
// config, it resolved a relative import, and it built and showed a menu.
//
// The non-ASCII titles are deliberate. They are a live check on the ordinal
// comparison work in StringCompare.h: 中 and 渭 differ only in the high byte of
// their UTF-16 code units, which the previous _memicmp-based comparison treated
// as equal, and Cyrillic А/а is a real case pair it never folded.

settings
{
	priority = 1
	exclude.where = !process.is_explorer
	// No showdelay, matching the shipped default. Setting it at all makes the
	// extension broadcast WM_SETTINGCHANGE to every top-level window twice per
	// menu, which is exactly the behaviour under test.
	tip.enabled = false
}

// Relative import. Resolving this without the process working directory being
// pointed at the install folder is the whole point of the load_import change.
import 'imports/vmtest-import.nss'

// Everything asserted on is a top-level item. Submenu contents are built lazily
// on WM_INITMENUPOPUP, so a submenu's items do not exist until it is opened and
// asserting on them from a single right-click would fail for reasons that have
// nothing to do with the code under test.
item(where=window.is_desktop title='VMTEST_SENTINEL_ROOT' pos=0 cmd='')
item(where=window.is_desktop title='VMTEST_ASCII' pos=1 cmd='')
item(where=window.is_desktop title='VMTEST_CJK_中' pos=2 cmd='')
item(where=window.is_desktop title='VMTEST_CJK_渭' pos=3 cmd='')
item(where=window.is_desktop title='VMTEST_CYR_А' pos=4 cmd='')
item(where=window.is_desktop title='VMTEST_CYR_а' pos=5 cmd='')
item(where=window.is_desktop title=vmtest_imported_title pos=6 cmd='')

// Locale selection, using the same shape as the shipped shell.nss. The import
// machinery roots a relative path against the importing file's directory, but
// it does that after evaluating the expression, so path.exists() below sees the
// path as written. loc_path is therefore absolute; a relative one resolves
// against the host process working directory - Explorer's - and never matches,
// which is how every non-English locale came to fall back to English.
//
// Install-Build.ps1 writes imports\lang\<guest user locale>.nss containing
// VMTEST_LOCALE_OK. If selection breaks, en.nss supplies VMTEST_LOCALE_FALLBACK
// instead and the expected-item assertion fails by name.
$loc_path = app.dir + '\imports\lang\'
import lang loc_path + "en.nss"

// Same three-step chain as the shipped shell.nss: full tag, then the bare
// language, then English. Install-Build.ps1 generates whichever of the first two
// can be distinguished from the fallback on this guest.
import lang if(path.exists(loc_path + sys.lang + ".nss"),
               loc_path + sys.lang + ".nss",
               if(path.exists(loc_path + sys.lang.name + ".nss"),
                  loc_path + sys.lang.name + ".nss",
                  loc_path + "en.nss"))

item(where=window.is_desktop title=loc.vmtest_locale pos=7 cmd='')

// Kept so the submenu path is still exercised, but nothing is asserted on its
// contents from a single right-click.
menu(where=window.is_desktop title='VMTEST_SENTINEL_MENU' pos=8)
{
	item(title='VMTEST_SUBITEM' cmd='')
}
