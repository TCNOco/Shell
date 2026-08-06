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
	showdelay = 0
	tip.enabled = false
}

// Relative import. Resolving this without the process working directory being
// pointed at the install folder is the whole point of the load_import change.
import 'imports/vmtest-import.nss'

menu(where=window.is_desktop title='VMTEST_SENTINEL_MENU' pos=0)
{
	item(title='VMTEST_ASCII' cmd='')
	item(title='VMTEST_CJK_中' cmd='')
	item(title='VMTEST_CJK_渭' cmd='')
	item(title='VMTEST_CYR_А' cmd='')
	item(title='VMTEST_CYR_а' cmd='')
	item(title=vmtest_imported_title cmd='')
}

item(where=window.is_desktop title='VMTEST_SENTINEL_ROOT' pos=0 cmd='')
