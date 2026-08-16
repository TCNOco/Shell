// ShellExt.h is self-contained, so this deliberately does not pull in <pch.h> -
// it lets the test project compile this file directly.
#include "Include\ShellExt.h"

// __except(EXCEPTION_EXECUTE_HANDLER); normally from Globals.h, spelled out here
// so this translation unit stays independent of the DLL's include order.
#ifndef except
#define except __except(EXCEPTION_EXECUTE_HANDLER)
#endif

namespace Nilesoft
{
	namespace Shell
	{
		// The selection the host is offering. pdtobj is the selected items; it is
		// null for a background click, where pidlFolder is the folder that was
		// clicked in. Those are different things and are kept apart: treating the
		// folder as a one-item selection would make sel.count read 1 when the user
		// has selected nothing.
		//
		// Raw pointers throughout, deliberately - __try cannot be used in a
		// function that needs C++ object unwinding, and this has to be guarded
		// because it executes inside hosts we do not control.
		IFACEMETHODIMP ShellExtHandler::Initialize(PCIDLIST_ABSOLUTE pidlFolder,
												   IDataObject *pdtobj, HKEY)
		{
			__try
			{
				IShellItemArray *sia = nullptr;

				if(pdtobj)
					::SHCreateShellItemArrayFromDataObject(pdtobj, IID_PPV_ARGS(&sia));

				ShellExtCapture::capture(sia, pdtobj == nullptr);

				if(sia)
					sia->Release();

				// Kept even with no selection: a background menu still wants to know
				// which folder it was raised in.
				ShellExtCapture::capture_folder(pidlFolder);
			}
			except
			{
				ShellExtCapture::clear();
			}

			// S_OK regardless. Failing here makes the host drop the handler
			// entirely, and we would rather build a menu with no selection - which
			// is exactly what happens today - than not be called at all.
			return S_OK;
		}

		// Binds the menu the host is about to build, so the TrackPopupMenu hook can
		// recognise it later by handle. Nothing is inserted.
		IFACEMETHODIMP ShellExtHandler::QueryContextMenu(HMENU hmenu, UINT, UINT, UINT,
														 UINT uFlags)
		{
			__try
			{
				// CMF_DEFAULTONLY means the host wants the default verb, not a menu
				// the user will see - a double-click, typically. Binding then would
				// attach the selection to a menu that is never shown.
				if(!(uFlags & CMF_DEFAULTONLY))
					ShellExtCapture::bind(hmenu);
			}
			except
			{
			}

			// Zero items added.
			return MAKE_HRESULT(SEVERITY_SUCCESS, FACILITY_NULL, 0);
		}

		HRESULT CreateShellExtFactory(REFIID riid, void **ppv)
		{
			auto factory = new(std::nothrow) ShellExtFactory();
			if(!factory)
				return E_OUTOFMEMORY;

			auto hr = factory->QueryInterface(riid, ppv);
			factory->Release();
			return hr;
		}
	}
}
