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
			// What a caller gets back. All three fields travel together or not at
			// all: an earlier version validated only the items and let the folder
			// and the background flag through raw, so a capture from one menu was
			// still being applied to the next one.
			struct view
			{
				IShellItemArray *items{};
				PCIDLIST_ABSOLUTE folder{};
				bool background{};

				explicit operator bool() const { return items != nullptr || folder != nullptr; }
			};

			// thread_local, not merely thread-checked. These used to be process-wide
			// with a stored thread id compared in match(): the check was per-thread
			// but the storage was not, so one thread's capture() could Release an
			// array another thread was about to read. Explorer runs several UI
			// threads. Initialize, QueryContextMenu and the TrackPopupMenu hook for
			// one menu all run on the same thread, which is exactly what makes
			// per-thread storage the right shape rather than a lock.
			inline static thread_local HMENU hmenu{};
			inline static thread_local IShellItemArray *items{};
			inline static thread_local PIDLIST_ABSOLUTE folder{};
			inline static thread_local bool background{};
			inline static thread_local uint32_t tick{};

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

			// All-or-nothing, matched on the menu handle and a short age. A capture
			// that does not belong to the menu being built must contribute nothing:
			// not its items, not its folder, and not its background flag.
			//
			// Getting this wrong was a real regression rather than a theoretical
			// one. When only the items were gated, a background right-click in
			// Explorer left folder and background set, and the very next address
			// bar, inline-rename, title-bar or Win+X menu - none of which have an
			// IShellBrowser, so all of which reach this code - was built as a
			// background click in whatever folder had last been clicked in.
			//
			// The age bound covers a host that asks for a handler and then never
			// shows a menu. Unsigned arithmetic, so GetTickCount wrapping at 49
			// days subtracts correctly.
			static view match(HMENU h)
			{
				if(!h || h != hmenu)
					return {};
				if((::GetTickCount() - tick) > 30000)
					return {};
				return { items, folder, background };
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
