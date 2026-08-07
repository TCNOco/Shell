settings
{
	priority=1
	exclude.where = !process.is_explorer

	// showdelay sets SPI_SETMENUSHOWDELAY, the delay before a submenu opens on
	// hover. That is a per-user system setting, and setting it here overrides
	// whatever the user chose, for the whole time a menu is open.
	//
	// It used to default to 200. Windows' own default is 400, so that looked
	// like an improvement - but anyone who had already tuned the setting down
	// got it forced back up. On a machine set to 0 it made submenus 200x slower
	// than the user asked for, which is the opposite of the point.
	//
	// Left unset, so the user's own setting applies. Uncomment to override:
	// showdelay = 200

	// Options to allow modification of system items
	modify.remove.duplicate=1
	tip.enabled=true
}

// localization
$loc_path='imports\lang\'
import lang loc_path + "en.nss"
import lang if(path.exists(loc_path + sys.lang + ".nss"),
               loc_path + sys.lang + ".nss",
               loc_path + "en.nss")

// or import lang 'imports/lang/en.nss'

import 'imports/theme.nss'
import 'imports/images.nss'
import 'imports/modify.nss'

menu(mode="multiple" title=loc.pin_unpin image=icon.pin)
{
}

menu(mode="multiple" title=title.more_options image=icon.more_options)
{
}

import 'imports/terminal.nss'
import 'imports/file-manage.nss'
import 'imports/develop.nss'
import 'imports/goto.nss'
import 'imports/taskbar.nss'
