// modify items
//
// What this file does NOT do any more, and why:
//
//   - It no longer deletes "Cast to device" and "Restore previous versions".
//     Silently removing Windows verbs from everyone's menu on install is not a
//     default anybody chose; it just looks like the feature is broken. (#666)
//
//   - It no longer moves thirteen verbs - send to, share, create shortcut, set
//     as desktop background, rotate left/right, map/disconnect network drive,
//     format, eject, give access to, include in library, print - into a "More
//     options" submenu. Every one of them is top level in Windows' own menu, so
//     burying them made the product look like it had lost them. (#629, #543)
//
//   - It no longer groups Pin/Unpin. That rule matched find="pin*" against the
//     LOCALIZED title, so it only ever worked in English, and Windows already
//     shows those two next to each other.
//
// The groupings that remain are genuine additions rather than rearrangements of
// what Windows ships, and they now match and target by identifier instead of by
// English text - see the note on the Terminal rule below.

modify(type="recyclebin" where=window.is_desktop and this.id==id.empty_recycle_bin pos=1 sep)

// menu= names the destination by the same expression the destination menu is
// declared with, not by an English literal. FindPattern matches against the
// localized title and the destination is resolved by comparing titles, so
// menu="file manage" silently dropped these items on every translated install -
// which nobody noticed only because locale selection was broken too.
modify(where=this.id==id.copy_as_path menu=loc.file_manage)
modify(type="dir.back|drive.back" where=this.id==id.customize_this_folder pos=1 sep="top" menu=loc.file_manage)

// By identifier, not by name. These resolve through Windows' own resource
// strings, so they match in every language; the previous
// str.equals(this.name, ["open in terminal", ...]) matched English only.
// WSL's "Open Linux shell here" has no identifier to match on, so it is left
// where Windows puts it rather than reintroducing a literal that only works
// for some users.
modify(where=this.id(id.terminal, id.open_command_window_here, id.open_powershell_window_here)
	pos="bottom" menu=title.terminal)
