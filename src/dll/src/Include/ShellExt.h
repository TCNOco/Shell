#pragma once

/*
	A real context-menu handler, so hosts other than Explorer can be served.

	The DLL has always been registered as one - under *, Directory, Drive,
	Folder, Directory\Background, DesktopBackground, LibraryFolder and
	LibraryFolder\Background, see RegistryConfig::RegisterContextMenuHandler -
	but DllGetClassObject returned E_NOTIMPL on every path. The registration
	existed only to make hosts load us; all the work was done by the
	NtUserTrackPopupMenuEx hook.

	That costs every host that is not Explorer. Selections::QuerySelected gets
	the selection through IShellBrowser, which it obtains by sending
	WM_GETISHELLBROWSER to the window. Third-party file managers implement
	their own view and answer nothing, so QuerySelected returns false at its
	has_IShellBrowser gate and the menu is built with no selection: theming
	works, anything selection-aware does not. Those hosts were already calling
	IShellExtInit::Initialize and handing us the selection outright, and we
	were throwing it away.

	So this is capability detection, not application detection. Any host that
	honours ContextMenuHandlers is served, and there is no per-application list
	to maintain in the DLL or in anyone's .nss.

	Two things this deliberately does not do:

	- It inserts no menu items. QueryContextMenu returns zero, so a host's menu
	  is exactly what it would have been. In Explorer, where the hook already
	  does everything, this object is inert by construction.

	- It does not identify our menu by putting a marker item in it. The HMENU
	  the host passes to QueryContextMenu is the same handle it later passes to
	  TrackPopupMenu, so the hook recognises its own menu with a pointer
	  compare. That is exact, costs nothing, and cannot be confused by an item
	  title.
*/

// Self-contained on purpose, so the test project can compile it without the
// DLL's include order: everything below needs only these four.
#include <windows.h>
#include <shlobj.h>
#include <atomic>
#include <new>

namespace Nilesoft
{
	namespace Shell
	{
		// Outstanding COM objects, so DllCanUnloadNow can answer honestly.
		// It used to decide from _loader.explorer alone and returned S_OK -
		// "nothing of mine is alive, unload me" - in every host that was not
		// explorer.exe. That was true only while we handed out no objects.
		inline std::atomic<long> com_object_count{ 0 };

		// The selection captured by the most recent IShellExtInit::Initialize and
		// the menu QueryContextMenu was handed. A context menu is modal and built
		// one at a time, so a single slot is enough: there is no map to grow, and
		// nothing to evict on a path that has to stay cheap.
		struct ShellExtCapture
		{
			inline static HMENU hmenu{};
			inline static IShellItemArray *items{};
			inline static PIDLIST_ABSOLUTE folder{};
			inline static bool background{};
			inline static uint32_t thread{};
			inline static uint32_t tick{};

			static void clear()
			{
				if(items)
				{
					items->Release();
					items = nullptr;
				}
				if(folder)
				{
					::CoTaskMemFree(folder);
					folder = nullptr;
				}
				hmenu = nullptr;
				background = false;
				thread = 0;
				tick = 0;
			}

			static void capture(IShellItemArray *sia, bool is_background)
			{
				clear();
				if(sia)
				{
					sia->AddRef();
					items = sia;
				}
				background = is_background;
				thread = ::GetCurrentThreadId();
				tick = ::GetTickCount();
			}

			// Cloned, not borrowed: the host owns pidlFolder and it is not valid
			// past the Initialize call.
			static void capture_folder(PCIDLIST_ABSOLUTE pidl)
			{
				if(folder)
				{
					::CoTaskMemFree(folder);
					folder = nullptr;
				}
				if(pidl)
					folder = ::ILCloneFull(pidl);
			}

			static void bind(HMENU h) { hmenu = h; }

			// Matched on the menu handle, the calling thread and a short age.
			//
			// The thread check is not defensive padding: the pointer is not
			// marshalled, and this DLL has no global interface table and makes no
			// apartment guarantee - ensure_com asks for STA but tolerates the
			// host's MTA. For a real context menu, Initialize, QueryContextMenu and
			// TrackPopupMenu all run on the host's UI thread, so this only refuses
			// the case that could not have been handled correctly anyway.
			//
			// The age bound covers a host that asks for a handler and then never
			// shows the menu, which would otherwise leave the last selection to be
			// picked up by an unrelated menu much later.
			static IShellItemArray *match(HMENU h)
			{
				if(!items || !h || h != hmenu)
					return nullptr;
				if(thread != ::GetCurrentThreadId())
					return nullptr;
				if((::GetTickCount() - tick) > 30000)
					return nullptr;
				return items;
			}
		};

		// IShellExtInit + IContextMenu. Every entry point is wrapped, because this
		// runs inside hosts we do not control and a fault here would take the
		// host's shell down rather than ours.
		class ShellExtHandler : public IShellExtInit, public IContextMenu
		{
			LONG m_ref = 1;

		public:
			ShellExtHandler() { com_object_count.fetch_add(1, std::memory_order_relaxed); }
			virtual ~ShellExtHandler() { com_object_count.fetch_sub(1, std::memory_order_relaxed); }

			// IUnknown
			IFACEMETHODIMP QueryInterface(REFIID riid, void **ppv) override
			{
				if(!ppv) return E_POINTER;
				*ppv = nullptr;

				if(riid == IID_IUnknown || riid == IID_IShellExtInit)
					*ppv = static_cast<IShellExtInit *>(this);
				else if(riid == IID_IContextMenu)
					*ppv = static_cast<IContextMenu *>(this);
				else
					return E_NOINTERFACE;

				AddRef();
				return S_OK;
			}

			IFACEMETHODIMP_(ULONG) AddRef() override
			{
				return static_cast<ULONG>(::InterlockedIncrement(&m_ref));
			}

			IFACEMETHODIMP_(ULONG) Release() override
			{
				auto n = ::InterlockedDecrement(&m_ref);
				if(n == 0)
					delete this;
				return static_cast<ULONG>(n);
			}

			// IShellExtInit. pdtobj carries the selection. pidlFolder is the folder
			// itself and is what a background (no-selection) click supplies.
			IFACEMETHODIMP Initialize(PCIDLIST_ABSOLUTE pidlFolder, IDataObject *pdtobj,
									  HKEY hkeyProgID) override;

			// IContextMenu
			IFACEMETHODIMP QueryContextMenu(HMENU hmenu, UINT indexMenu, UINT idCmdFirst,
											UINT idCmdLast, UINT uFlags) override;

			// Nothing is inserted, so neither of these can be reached for an item of
			// ours. They exist because the interface requires them.
			IFACEMETHODIMP InvokeCommand(CMINVOKECOMMANDINFO *) override { return E_INVALIDARG; }

			IFACEMETHODIMP GetCommandString(UINT_PTR, UINT, UINT *, CHAR *, UINT) override
			{
				return E_INVALIDARG;
			}
		};

		// Defined in ShellExt.cpp. DllGetClassObject wraps its body in __try, and
		// MSVC will not accept __try in a function that also needs C++ object
		// unwinding (C2712), so the construction lives out of line.
		HRESULT CreateShellExtFactory(REFIID riid, void **ppv);

		class ShellExtFactory : public IClassFactory
		{
			LONG m_ref = 1;

		public:
			ShellExtFactory() { com_object_count.fetch_add(1, std::memory_order_relaxed); }
			virtual ~ShellExtFactory() { com_object_count.fetch_sub(1, std::memory_order_relaxed); }

			IFACEMETHODIMP QueryInterface(REFIID riid, void **ppv) override
			{
				if(!ppv) return E_POINTER;
				*ppv = nullptr;

				if(riid == IID_IUnknown || riid == IID_IClassFactory)
				{
					*ppv = static_cast<IClassFactory *>(this);
					AddRef();
					return S_OK;
				}
				return E_NOINTERFACE;
			}

			IFACEMETHODIMP_(ULONG) AddRef() override
			{
				return static_cast<ULONG>(::InterlockedIncrement(&m_ref));
			}

			IFACEMETHODIMP_(ULONG) Release() override
			{
				auto n = ::InterlockedDecrement(&m_ref);
				if(n == 0)
					delete this;
				return static_cast<ULONG>(n);
			}

			IFACEMETHODIMP CreateInstance(IUnknown *pUnkOuter, REFIID riid, void **ppv) override
			{
				if(!ppv) return E_POINTER;
				*ppv = nullptr;
				if(pUnkOuter) return CLASS_E_NOAGGREGATION;

				auto obj = new(std::nothrow) ShellExtHandler();
				if(!obj) return E_OUTOFMEMORY;

				auto hr = obj->QueryInterface(riid, ppv);
				obj->Release();
				return hr;
			}

			IFACEMETHODIMP LockServer(BOOL lock) override
			{
				if(lock)
					com_object_count.fetch_add(1, std::memory_order_relaxed);
				else
					com_object_count.fetch_sub(1, std::memory_order_relaxed);
				return S_OK;
			}
		};
	}
}
