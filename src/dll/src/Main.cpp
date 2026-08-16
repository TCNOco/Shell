#include <pch.h>
#include "Include/ContextMenu.h"
#include "Include/ShellExt.h"
#include "Library/detours.h"
#include "RegistryConfig.h"
#include <UIAutomation.h>
using namespace Nilesoft::Shell;
using namespace Diagnostics;

//MS also offers EV Code Certificates, which enable immediate acceptance by SmartScreeen of Windows Defender
//https://blogs.msdn.microsoft.com/ie/2012/08/14/microsoft-smartscreen-extended-validation-ev-code-signing-certificates/

#ifdef _DEBUG
#include <crtdbg.h>
#endif
/*
Windows 10
Version Build
-------------
1507	10240
1511	10586
1607	14393
1703	15063
1709	16299
1803	17134
1809	17763
1903	18362
1909	18363
2004	19041
20H2	19042
21H1	19043
21H2	19044
22H2	19045
*/

//#pragma comment(lib, "mincore.lib")
//#pragma comment(lib, "shlwapi.lib")
#pragma comment(lib, "UxTheme.lib")
#pragma comment(lib, "Comctl32.lib")
#pragma comment(lib, "dwmapi.lib")
#pragma comment(lib, "WindowsCodecs.lib")
// d2d1, dwrite and Winmm were here. Nothing references them any more: the
// Direct2D renderer was unreachable, and the vblank sleep that was winmm's only
// caller is gone. Linking an unreferenced import lib is silent, so these were
// harmless, but they suggested dependencies the binary does not have.
#pragma comment(lib, "oleaut32.lib")
#pragma comment(lib, "Shlwapi.lib")

// plutovg is a second library since upstream split it out of plutosvg; the
// old prebuilt plutosvg-*.lib bundled both. Order matters for the linker:
// plutosvg references plutovg.
#if defined(_M_ARM64)
#pragma comment(lib, "plutosvg-arm64.lib")
#pragma comment(lib, "plutovg-arm64.lib")
#pragma comment(lib, "detours-arm64.lib")
// No _M_ARM branch. The solution builds Win32, x64 and ARM64 only, and neither
// plutosvg-arm.lib nor detours-arm.lib exists in shared\Library, so the arm32
// case advertised a target that could never have linked.
#elif defined(_M_X64)
#pragma comment(lib, "plutosvg-x64.lib")
#pragma comment(lib, "plutovg-x64.lib")
#pragma comment(lib, "detours-x64.lib")
#elif defined(_M_IX86)
#pragma comment(lib, "plutosvg-x86.lib")
#pragma comment(lib, "plutovg-x86.lib")
#pragma comment(lib, "detours-x86.lib")
#endif

//#pragma optimize("ts", on) 

/*
#if defined(_M_X64)
#pragma comment(linker, "/export:DllCanUnloadNow=_DllCanUnloadNow")
#else
#pragma comment(linker, "/export:DllCanUnloadNow=__DllCanUnloadNow@0")
#endif
*/

#ifdef _DEBUG

std::unordered_map< uint32_t, const wchar_t *> msg_map0 = {
	{ WM_DESTROY, L"WM_DESTROY" },
	{ WM_NCDESTROY, L"WM_NCDESTROY" },
	{ WM_CREATE, L"WM_CREATE" },
	{ WM_NCCREATE, L"WM_NCCREATE" },
	{ WM_PAINT, L"WM_PAINT" },
	{ WM_NCPAINT, L"WM_NCPAINT" },
	{ WM_PRINTCLIENT, L"WM_PRINTCLIENT" },
	{ WM_PRINT, L"WM_PRINT" },
	{ WM_NCCALCSIZE, L"WM_NCCALCSIZE" },
	{ WM_ERASEBKGND, L"WM_ERASEBKGND" },
	{ MN_SELECTITEM, L"MN_SELECTITEM" },
	{ WM_KEYDOWN, L"WM_KEYDOWN" },
	{ WM_WINDOWPOSCHANGED, L"WM_WINDOWPOSCHANGED" },
	{ WM_WINDOWPOSCHANGING, L"WM_WINDOWPOSCHANGING" },
	{ WM_NCHITTEST, L"WM_NCHITTEST" },
	{ WM_TIMER, L"WM_TIMER" },
	{ WM_SIZE, L"WM_SIZE" },
	{ WM_MOVE, L"WM_MOVE" },
	{ MN_SIZEWINDOW, L"MN_SIZEWINDOW" },
	{ MN_DBLCLK, L"MN_DBLCLK" },
	{ MN_CLOSEHIERARCHY, L"MN_CLOSEHIERARCHY" },
	{ MN_SETTIMERTOOPENHIERARCHY, L"MN_SETTIMERTOOPENHIERARCHY" },
	{ MN_FINDMENUWINDOWFROMPOINT, L"MN_FINDMENUWINDOWFROMPOINT" },
	{ MN_ENDMENU, L"MN_ENDMENU" },
	{ MN_CANCELMENUS, L"MN_CANCELMENUS" },
	{ MN_BUTTONDOWN, L"MN_BUTTONDOWN" },
	{ MN_BUTTONUP, L"MN_BUTTONUP" },
	{ WM_UAHDESTROYWINDOW, L"WM_UAHDESTROYWINDOW" },
	{ WM_UAHMEASUREMENUITEM, L"WM_UAHMEASUREMENUITEM" },
	{ WM_UAHINITMENUPOPUP, L"WM_UAHINITMENUPOPUP" },
	{ WM_UAHNCPAINTMENUPOPUP, L"WM_UAHNCPAINTMENUPOPUP" },
	{ WM_UAHDRAWMENU, L"WM_UAHDRAWMENU" },
	{ WM_NCUAHDRAWFRAME, L"WM_NCUAHDRAWFRAME" },
	{ WM_UAHDRAWMENUITEM, L"WM_UAHDRAWMENUITEM" },
	{ WM_ENTERMENULOOP, L"WM_ENTERMENULOOP" },
	{ WM_EXITMENULOOP, L"WM_EXITMENULOOP" },
	{ WM_INITMENU, L"WM_INITMENU" },
	{ WM_INITMENUPOPUP, L"WM_INITMENUPOPUP" },
	{ WM_UNINITMENUPOPUP, L"WM_UNINITMENUPOPUP" },
	{ WM_MENUSELECT, L"WM_MENUSELECT" },
	{ WM_NEXTMENU, L"WM_NEXTMENU" },
	{ WM_MENUCHAR, L"WM_MENUCHAR" },
	{ WM_MEASUREITEM, L"WM_MEASUREITEM" },
	{ WM_DRAWITEM, L"WM_DRAWITEM" },
	{ WM_MENUCOMMAND, L"WM_MENUCOMMAND" },
	{ WM_COMMAND, L"WM_COMMAND" },
	{ WM_SYSCOMMAND, L"WM_SYSCOMMAND" },
	{ WM_MENURBUTTONUP, L"WM_MENURBUTTONUP" },
	{ WM_CAPTURECHANGED, L"WM_CAPTURECHANGED" },
	{ WM_ENTERIDLE, L"WM_ENTERIDLE" },
	{ WM_SETCURSOR, L"WM_SETCURSOR" },
	{ WM_SHOWWINDOW , L"WM_SHOWWINDOW" },
	{ WM_PARENTNOTIFY, L"WM_PARENTNOTIFY"},
	{ WM_MOUSEACTIVATE, L"WM_MOUSEACTIVATE"},
	{ WM_CONTEXTMENU, L"WM_CONTEXTMENU"},
	{ WM_NOTIFY, L"WM_NOTIFY"},
	{ WM_SETFOCUS, L"WM_SETFOCUS"},
	{ WM_KILLFOCUS, L"WM_KILLFOCUS"},
	{ WM_GETOBJECT, L"WM_GETOBJECT"},
	{ WM_ACTIVATE, L"WM_ACTIVATE"},
	{ WM_NCACTIVATE, L"WM_NCACTIVATE"},
	{ WM_ACTIVATEAPP, L"WM_ACTIVATEAPP"},
	{ WM_CHANGEUISTATE, L"WM_CHANGEUISTATE"},
	{ WM_IME_SETCONTEXT, L"WM_IME_SETCONTEXT"},
	{ WM_IME_NOTIFY, L"WM_IME_NOTIFY"},
	{ WM_MOUSEMOVE, L"WM_MOUSEMOVE"},
	{WM_DEVICECHANGE, L"WM_DEVICECHANGE"},
	{WM_IME_REQUEST, L"WM_IME_REQUEST"},
	{MN_GETHMENU, L"MN_GETHMENU"},
	{WM_LBUTTONDOWN, L"WM_LBUTTONDOWN"},
	{WM_RBUTTONDOWN, L"WM_RBUTTONDOWN"},
	{WM_LBUTTONUP, L"WM_LBUTTONUP"},
	{WM_RBUTTONUP, L"WM_RBUTTONUP"},
	{WM_MOUSELEAVE,L"WM_MOUSELEAVE"},
	{WM_USER, L"WM_USER"},
	{WM_APP, L"WM_APP"},
	{ 0, nullptr }
};

#endif

#pragma region Entry Point

#define GET_X_LPARAM(lp) ((int)(short)LOWORD(lp))  // windowsx.h
#define GET_Y_LPARAM(lp) ((int)(short)HIWORD(lp))  // windowsx.h

HINSTANCE _hInstance{};
Initializer _initializer;
extern Logger &_log = Logger::Instance();
const Windows::Version *ver = &Windows::Version::Instance();

HANDLE watch_event = nullptr;

WindowsHook _taskbar_mouse;

//std::unordered_map<HMODULE, IATHook> _detours_ci;
IATHook iathook_NtUserTrackPopupMenuEx;
std::vector<IATHook> iathook_TrackPopupMenu; //OverrideFunction
//Detours<decltype(::TrackPopupMenu)> _TrackPopupMenu;
//Detours<decltype(::TrackPopupMenuEx)> _TrackPopupMenuEx;
Detours<decltype(::DllGetClassObject)> _DllGetClassObject;
Detours<decltype(::CoCreateInstance)> _CoCreateInstance;

uint32_t MN_CONTEXTMENU = 0;
std::unordered_map<HWND, Window> _window_taskbar;

LRESULT __stdcall TaskbarSubclassProc(HWND hWnd, UINT uMsg, WPARAM wParam, LPARAM lParam, UINT_PTR uIdSubclass, DWORD_PTR dwRefData);
LRESULT __stdcall TaskbarProc(HWND hWnd, UINT uMsg, WPARAM wParam, LPARAM lParam);

__inline auto is_registered() -> bool
{
	//auto_regkey r;
	//return ERROR_SUCCESS == auto_regkey::exists_key(HKCR, HKCR_CLSID_ContextMenu);
	return RegistryConfig::IsRegistered();
}

struct
{
	string path;
	bool explorer{};
	bool contextmenuhandler{};
	HMODULE handle{};

	bool init()
	{
		handle = ::GetModuleHandleW(nullptr);
		if(!(explorer) && path.empty())
		{
			path = Path::Module(nullptr);
			explorer = path.ends_with(def_EXPLORER, true);
		}
		return explorer;
	}

	explicit operator bool() const { return explorer; }

} _loader;

struct taskbar_t
{
	inline static IComPtr<IUIAutomation> _IUIAutomation;
	inline static auto wShell_TrayWnd = ::RegisterWindowMessageW(Windows::WC_Shell_TrayWnd);
	inline static auto wShell_SecondaryTrayWnd = ::RegisterWindowMessageW(Windows::WC_Shell_SecondaryTrayWnd);

	static bool hook(HWND hTaskbar, UINT_PTR id)
	{
		Window window = Window::Find(Windows::WC_Composition_DesktopWindowContentBridge, hTaskbar);
		if(window && !window.is_prop(UxSubclass))
		{
			if(!_window_taskbar.contains(window))
			{
				if(window.subclass(TaskbarSubclassProc, id, hTaskbar))
				{
					window.prop(UxSubclass, CONTEXTMENUSUBCLASS);
					_window_taskbar[window] = window;
					return true;
				}
			}
		}
		return false;
	}

	static void try_hook(HWND hTaskbar, UINT_PTR id, int time = 500)
	{
		if(hTaskbar)
		{
			::SetTimer(hTaskbar, id, time, [](HWND hWnd, UINT, UINT_PTR id, DWORD)
			{
				static int atttempt = 0;
				if(hook(hWnd, id))
					atttempt = 50;
				if(atttempt++ >= 50)
					::KillTimer(hWnd, id);
			});
		}
	}

	static void hook_all()
	{
		::EnumWindows([](HWND hWnd, LPARAM)->BOOL {
			auto atom = Window::Atom(hWnd);
			if(atom == wShell_TrayWnd || atom == wShell_SecondaryTrayWnd)
			{
				Window window = hWnd;
				if(!window.is_prop(UxSubclass))
				{
					if(!_window_taskbar.contains(window))
					{
						auto proc = window.get_long(GWLP_WNDPROC);
						window.prop(UxSubclass, proc);
						window.set_long(GWLP_WNDPROC, TaskbarProc);
						_window_taskbar[window] = window;
						return true;
					}
				}
			}
			return TRUE;
		}, 0);
	}

	static void hook_all(uint32_t delay)
	{
		::SetTimer(::GetShellWindow(), 0, delay, [](HWND hWnd, UINT, UINT_PTR id, DWORD)
		{						
			static int atttempt = 0;
			if(atttempt++ >= 10)
				::KillTimer(hWnd, id);
			
			taskbar_t::hook_all();
		});
	}
	
	static void unhook(HWND hWnd)
	{
		for(auto &window : _window_taskbar)
		{
			if(window.first == hWnd)
			{
				window.second.set_long(GWLP_WNDPROC, window.second.prop(UxSubclass));
				window.second.remove_prop(UxSubclass);
				_window_taskbar.erase(hWnd);
				break;
			}
		}
	}
	static void unhook_all()
	{
		for(auto &window : _window_taskbar)
		{
			window.second.set_long(GWLP_WNDPROC, window.second.prop(UxSubclass));
			window.second.remove_prop(UxSubclass);
			_window_taskbar.erase(window.first);
			break;
		}
		_window_taskbar.clear();
	}

	static bool is_allowed_area(HWND hTaskbar, const Point &pt)
	{
		// ElementFromPoint plus three property gets is four cross-apartment round
		// trips, taken on the thread pumping the taskbar's messages. One right-click
		// asks this twice - once from WM_MOUSEACTIVATE and again from WM_CONTEXTMENU,
		// with the cursor in the same place both times - so the answer is memoised
		// just long enough to cover a single click. A later click at the same point
		// re-reads the tree, so a tray icon appearing under the cursor is not missed.
		// thread_local because the primary and secondary taskbars need not be pumped
		// by the same thread.
		static thread_local HWND cached_hwnd = nullptr;
		static thread_local Point cached_pt{};
		static thread_local uint32_t cached_tick = 0;
		static thread_local bool cached_ret = false;

		const auto now = ::GetTickCount();
		if(hTaskbar == cached_hwnd && pt.x == cached_pt.x && pt.y == cached_pt.y
		   && (now - cached_tick) < 250)
			return cached_ret;

		bool ret = false;

		if(!_IUIAutomation)
			_IUIAutomation.CreateInstance(__uuidof(CUIAutomation), CLSCTX_INPROC_SERVER);

		if(_IUIAutomation)
		{
			IComPtr<IUIAutomationElement> pIUIAutomationElement;
			if(SUCCEEDED(_IUIAutomation->ElementFromPoint(pt, pIUIAutomationElement)) && pIUIAutomationElement)
			{
				struct elem_t {
					BSTR type = nullptr;
					BSTR name = nullptr;
					BSTR id = nullptr;
					~elem_t() {
						freeString(type);
						freeString(name);
						freeString(id);
					}
					void freeString(BSTR s) {
						if(s) DLL::Invoke(L"OleAut32.dll", "SysFreeString", s);
					}
				} elem;
				
				pIUIAutomationElement->get_CurrentAutomationId(&elem.id);
				pIUIAutomationElement->get_CurrentClassName(&elem.type);
				pIUIAutomationElement->get_CurrentName(&elem.name);
				/*
				id=[TaskbarFrame], type=[Taskbar.TaskbarFrameAutomationPeer], name=[]
				id=[StartButton], type=[ToggleButton], name=[Start]
				id=[SearchButton], type=[ToggleButton], name=[Search]
				id=[SystemTrayIcon], type=[SystemTray.NormalButton], name=[Show Hidden Icons]
				id=[SystemTrayIcon], type=[SystemTray.AccentButton], name=[Network wifi-1 Internet access]
				id=[SystemTrayIcon], type=[SystemTray.OmniButton], name=[Clock 7:04 PM 3/20/2023]
				id=[SystemTrayIcon], type=[SystemTray.ShowDesktopButton], name=[Show Desktop]
				*/
				if(elem.name && elem.type && elem.id)
				{
					if(!::lstrcmpiW(elem.id, L"TaskbarFrame"))
						ret = !::lstrcmpiW(elem.name, L"") && !::lstrcmpiW(elem.type, L"Taskbar.TaskbarFrameAutomationPeer");
					else if(is_secondary(hTaskbar))
					{
						if(!::lstrcmpiW(elem.id, L"SystemTrayIcon"))
							ret = !::lstrcmpiW(elem.type, L"SystemTray.OmniButton");
					}
				}

				// The strings matched above were taken from a Windows 11 21H2
				// automation tree. When a later build renames them nothing matches,
				// this returns false, and the taskbar falls back to Windows' own
				// menu - the right way to fail, but it leaves no trace of what the
				// names became. __trace compiles to nothing unless TRACE is defined,
				// so this costs a release build nothing and does not help a user
				// report either; it is here so that reproducing the problem in a
				// debug build prints the actual tree instead of needing this
				// instrumentation written from scratch first.
				__trace(L"taskbar element id=[%s] type=[%s] name=[%s] allowed=%d",
						elem.id ? elem.id : L"", elem.type ? elem.type : L"",
						elem.name ? elem.name : L"", ret ? 1 : 0);
			}
		}

		cached_hwnd = hTaskbar;
		cached_pt = pt;
		cached_tick = now;
		cached_ret = ret;
		return ret;
	}

	static bool is_primary(HWND hTaskbar)
	{
		if(hTaskbar)
		{
			Window taskbar = hTaskbar;
			if(taskbar.hash() == WindowClass::WC_Shell_TrayWnd)
			{
				// Only the primary taskbar has a RebarWindow32
				return taskbar.find(Windows::WC_ReBarWindow32);
			}
		}
		return false;
	}

	static bool is_secondary(HWND hTaskbar)
	{
		return hTaskbar && (Window::class_hash(hTaskbar) == WindowClass::WC_Shell_SecondaryTrayWnd);
	}
};

HRESULT __stdcall CoCreateInstanceHook(REFCLSID rclsid, LPUNKNOWN pUnkOuter, DWORD dwClsContext, REFIID riid, LPVOID *ppv)
{
	auto is_local_server = (dwClsContext & CLSCTX_LOCAL_SERVER) != 0;
	auto is_inproc_server = (dwClsContext & CLSCTX_INPROC_SERVER) != 0;

	if(_initializer.cache && (is_inproc_server || is_local_server))
	{
		auto hr = E_NOINTERFACE; //CLASS_E_CLASSNOTAVAILABLE;
		auto process = true;

		if(rclsid == IID_FileExplorerContextMenu /*&& riid == {706461D1-AC5F-4730-BFE3-CAC6CAD5EF5E}*/)
		{
			if(_initializer.cache->settings.priority)
			{
				Context context;
				Object obj = context.Eval(_initializer.cache->settings.priority).move();
				if(obj.is_number())
					process = obj;
			}

			if(process)
				return hr;
		}
		else
		{
			/*auto xx = Guid(L"{f3d06e7c-1e45-4a26-847e-f9fcdee59be0}");

			if(xx.equals({riid,rclsid}))
			{
				MB(L"0000000000000");
			}*/

			//if(riid== IID_IExplorerCommandProvider)
			//	_log.info(L"IID_IExplorerCommandProvider %s", Guid(rclsid).to_string(2).c_str());

			//if(riid == IID_IExecuteCommand)
			//	_log.info(L"IID_IExecuteCommand %s", Guid(rclsid).to_string(2).c_str());
			/*
			if(riid == IID_IExplorerCommandState)
			{
				hr = _CoCreateInstance.invoke(rclsid, pUnkOuter, dwClsContext, riid, ppv);

				auto cc = (IExplorerCommand *)*ppv;

				IExplorerCommand *f = 0;
				cc->QueryInterface(IID_IExplorerCommand, (void**)&f);
				//printto;rotate90;rotate270;setwallpaper;slideshow

				LPWSTR p;
				f->GetTitle(0, &p);
				_log.info(L"IExplorerCommandState %s", p);
				return hr;
			}
		*/
			auto is_UWP = false;
			process = false;
			/*
			if(Guid(rclsid).equals(L"{E6950302-61F0-4FEB-97DB-855E30D4A991}"))
			{
				*ppv = new ExplorerCommandBase;
				return S_OK;
			}
			*/
			if(is_inproc_server)
				process = riid == IID_IContextMenu || riid == IID_IContextMenu2 || riid == IID_IContextMenu3 || riid == IID_IExplorerCommand;
			else
			{
				process = riid == IID_IExplorerCommand;
				is_UWP = is_local_server && process;
			}

			if(process)
			{
				Context context;
				this_item _this; context._this = &_this;
				_this.is_uwp = is_UWP;
				_this.clsid = Guid(rclsid).to_string(2);

				// Holding Alt used to divert into a timing path that wrote a line to
				// shell.log and returned early. This hook runs on every COM activation
				// on every thread of the host, so that cost a GetAsyncKeyState per
				// activation, and when Alt happened to be down, a CreateFile/Write/
				// CloseHandle round trip under a global mutex on the menu path -
				// Logger reopens the file for each write. Returning early also skipped
				// the suppression below, so an undocumented modifier silently changed
				// which shell extensions were filtered.
				for(auto si : _initializer.cache->statics)
				{
					if(si->clsid.empty() || (si->where && !context.eval_bool(si->where)))
						continue;

					if(si->has_clsid)
					{
						for(auto &id : si->clsid)
						{
							if(id.equals(rclsid))
								return E_NOINTERFACE;
						}
					}
				}

			}
		}
	}

	return _CoCreateInstance.invoke(rclsid, pUnkOuter, dwClsContext, riid, ppv);
}

STDAPI WINAPI DllGetClassObjectHook(REFCLSID rclsid, _In_ REFIID riid, LPVOID *ppv)
{
	auto hr = CLASS_E_CLASSNOTAVAILABLE;
	if(IID_FileExplorerContextMenu == rclsid/* || rclsid == IID_FileExplorerCommandBar*/)
		return hr;
	hr = _DllGetClassObject.invoke(rclsid, riid, ppv);
	return hr;
}

#define TPM_SYSMENU	0x0200L
bool is_in_taskbar;

BOOL WINAPI TrackPopupMenuProc(HMENU hMenu, uint32_t uFlags, int x, int y, int nReserved, HWND hWnd, const RECT *prcRect);
BOOL WINAPI TrackPopupMenuExProc(HMENU hMenu, uint32_t uFlags, int x, int y, HWND hWnd, LPTPMPARAMS lptpm);

BOOL WINAPI NtUserTrackPopupMenu(HMENU hMenu, uint32_t uFlags, int x, int y, HWND hWnd, LPTPMPARAMS lptpm, int tfunc)
{
#ifdef _DIJA
	return (BOOL)XXX::OnContextMenu(hWnd, x, y, hMenu);;
#endif

	auto result = FALSE;
	auto invoked = false;

	auto invoke = [&](HMENU hmenu, uint32_t flag, Point pt)
	{
		if(!invoked)
		{
			if(tfunc == 0)
				result = ::TrackPopupMenu(hmenu, flag, pt.x, pt.y, 0, hWnd, nullptr);
			else if(iathook_NtUserTrackPopupMenuEx.installed())
				result = iathook_NtUserTrackPopupMenuEx.invoke<decltype(TrackPopupMenuExProc)>(hmenu, flag, pt.x, pt.y, hWnd, lptpm);
			else
				result = ::TrackPopupMenuEx(hmenu, flag, pt.x, pt.y, hWnd, lptpm);
			invoked = true;
		}
	};

	__try
	{
		__try
		{

			if(!is_registered())
			{
				__trace(L"TrackPopupMenu unregistered");
				__leave;
			}

			//cs.lock();
			auto has_inited = 0; Initializer::OnState(is_in_taskbar);

			if(!_initializer.Status.Disabled)
			{
				// is injected from explorer
				if(!_initializer.Status.Loaded)
				{
					if(_initializer.has_error() || has_inited)
						__leave; //goto skip;
					_initializer.init();
				}

				auto ctx = ContextMenu::CreateAndInitialize(hWnd, hMenu, { x, y }, _loader.explorer, _loader.contextmenuhandler);
				if(ctx != nullptr)
				{

					Flag<uint32_t> flag(uFlags);
					//Selections::point = { x, y };
					//	flag.remove(TPM_RETURNCMD);
					flag.remove(TPM_NONOTIFY);
					//	flag.remove(TPM_NOANIMATION);

				//	flag.add(TPM_HORPOSANIMATION);

				//	BOOL v = 1;
				//	SystemParametersInfoW(SPI_SETMENUANIMATION, 0, &v, SPIF_SENDCHANGE);
				//	v = 0;
				//	SystemParametersInfoW(SPI_GETMENUFADE, 0, &v, SPIF_SENDCHANGE);
					
					if(ctx->is_layoutRTL == 1)
						flag.add(TPM_LAYOUTRTL);
					else if(ctx->is_layoutRTL == 0)
						flag.remove(TPM_LAYOUTRTL);

					auto z = ctx->_theme.border.size + ctx->_theme.border.size;

					if(ctx->Selected.Window.parent == WINDOW_TASKBAR)
					{
						HWND hTaskbar = hWnd;
						if(ctx->Selected.Window.id == WINDOW_START)
							hTaskbar = ::WindowFromPoint({ x, y });
						else
							hTaskbar = ::GetAncestor(hWnd, GA_ROOTOWNER);

						if(!hTaskbar)
							hTaskbar = hWnd;

						Monitor monitor(hTaskbar);
						monitor.info();

						Rect rcW = monitor.rcWork;
						Rect rcM = monitor.rcMonitor;
						Rect rc = hTaskbar;

						if(ctx->Selected.Window.id == WINDOW_START)
						{
							if(rc.top > 0)
								y = (rc.top + 5) - (z + ctx->_theme.border.padding.height());
							else if(rc.left == 0)
								y = rc.bottom;
							else
								x = rc.left;
						}
						else
						{
							if(rcM.top == rc.top && rcM.bottom == rc.bottom) // Vertical
							{
								if(rcM.left == rc.left)
									x = rc.right;
								else if(rcM.right == rc.right)
									x = rc.left - 20;
							}
							else if(rcM.left == rc.left && rcM.right == rc.right) // Horizontal
							{
								if(rcM.top == rc.top)
									y = rc.bottom;
								else if(rcM.bottom == rc.bottom)
									y = (rc.top + 5) - (z + ctx->_theme.border.padding.height());
							}
						}
					}
					else
					{
						y -= z;
					}
					
					invoke(ctx->MenuHandle(), flag, { x, y });
				
					// v = 0;
					// SystemParametersInfoW(SPI_SETMENUANIMATION, 0, &v, SPIF_SENDCHANGE);
					result = ctx->InvokeCommand(result);
					__leave;
				}
			}
		}
		except
		{
#ifdef _DEBUG
			_log.exception(__func__);
#endif
		}
	}
	__finally
	{
		invoke(hMenu, uFlags, { x, y });
		_loader.contextmenuhandler = false;
		// Bounds the captured selection to the menu that used it. Without this it
		// survived until the next IShellExtInit::Initialize, which for menus the
		// host does not route through a shell handler is never - so the last
		// right-click's folder stayed live and was applied to later, unrelated
		// menus. It also stops one IShellItemArray and one PIDL being held for as
		// long as the process lives.
		ShellExtCapture::clear();
		is_in_taskbar = false;
		return result;
	}
}

BOOL WINAPI TrackPopupMenuProc(HMENU hMenu, uint32_t uFlags, int x, int y, [[maybe_unused]] int nReserved, HWND hWnd, [[maybe_unused]] const RECT *prcRect)
{
	//_log.write(L"%s\n", Window::class_name(hWnd).c_str());
	return NtUserTrackPopupMenu(hMenu, uFlags, x, y, hWnd, nullptr, 0);
}

//win32u.dll win10 1607	Redstone 1 14393
BOOL WINAPI TrackPopupMenuExProc(HMENU hMenu, uint32_t uFlags, int x, int y, HWND hWnd, LPTPMPARAMS lptpm)
{
	//_log.write(L"%s\n", Window::class_name(hWnd).c_str());
	return NtUserTrackPopupMenu(hMenu, uFlags, x, y, hWnd, lptpm, 1);
}

bool ShowTaskbarContextMenu(HWND hTaskbar, const Point &pt, uint32_t uMsg)
{
	auto ret = false;
	//if(taskbar_t::is_allowed_area(hTaskbar, pt))
	{
		struct menu {
			HMENU handle{};
			menu() { handle = ::CreatePopupMenu(); }
			~menu() { if(handle) ::DestroyMenu(handle); }
		}_menu;

		if(_menu.handle)
		{
			is_in_taskbar = true;
			//::SetForegroundWindow(hTaskbar);
			auto uFlags = TPM_RETURNCMD | TPM_RIGHTBUTTON | (::GetSystemMetrics(SM_MIDEASTENABLED) ? TPM_LAYOUTRTL : 0);
			if(uMsg == WM_CONTEXTMENU)
			{
				//_log.info(L"************");
				TrackPopupMenuExProc(_menu.handle, uFlags, pt.x, pt.y, hTaskbar, nullptr);
			}
			else 
			{
				iathook_NtUserTrackPopupMenuEx.invoke<decltype(TrackPopupMenuExProc)>(_menu.handle, uFlags, 0, 0, hTaskbar, nullptr);
			}
			::PostMessageW(hTaskbar, WM_NULL, 0, 0); // send benign message to window to make sure the menu goes away.
			ret = true;
		}
	}
	return ret;
}

LRESULT __stdcall TaskbarProc(HWND hWnd, UINT uMsg, WPARAM wParam, LPARAM lParam)
{
	auto wndproc = (WNDPROC)::GetPropW(hWnd, UxSubclass);
	
	if(wndproc == nullptr)
		return ::DefWindowProcW(hWnd, uMsg, wParam, lParam);

	if(uMsg == WM_CONTEXTMENU)
	{
		auto pt = Point::CursorPos();
		if(taskbar_t::is_allowed_area(hWnd, pt))
		{
			if(ShowTaskbarContextMenu(hWnd, pt, wParam == 0 && lParam == 0 ? WM_RBUTTONDOWN : WM_CONTEXTMENU))
				return 0;
		}
	}
	else if(uMsg == WM_MOUSEACTIVATE)
	{
		auto msg = HIWORD(lParam);
		if(msg != WM_RBUTTONDOWN)
			return wndproc(hWnd, uMsg, wParam, lParam);

		auto pt = Point::CursorPos();

		if(taskbar_t::is_allowed_area(hWnd, pt))
		{
			int disabled_taskbar = 0;
			if(RegistryConfig::get(L"\\disable", L"taskbar", disabled_taskbar) && disabled_taskbar == 1)
				return wndproc(hWnd, uMsg, wParam, lParam);

			if(msg == WM_RBUTTONDOWN)
			{
				Keyboard kb;
				if(auto count = kb.get_keys_excloude_contextmenu(); count > 0)
				{
					if(kb.key_ctrl())
					{
						if(count == 2 && kb.key_win())
							return wndproc(hWnd, uMsg, wParam, lParam);

						if(count == 1 && !_initializer.has_error())
						{
							if(!_initializer.Status.Loaded)
								_initializer.OnState();
						}
					}
				}
			}

			if(_initializer.has_error())
			{
				_initializer.OnState();
				if(_initializer.has_error())
					return wndproc(hWnd, uMsg, wParam, lParam);
			}
			else
			{
				if(_initializer.Status.Disabled)
					return wndproc(hWnd, uMsg, wParam, lParam);
			}

			if(!is_registered())
			{
				return wndproc(hWnd, uMsg, wParam, lParam);
			}

			::SetFocus(hWnd);
			::SendMessageW(hWnd, WM_CONTEXTMENU, 0, 0);

			return MA_ACTIVATEANDEAT;
		}
	}
	else if(uMsg == WM_SETTINGCHANGE)
	{
		if(SPI_SETWORKAREA == wParam && ::GetSystemMetrics(SM_CMONITORS) > 1)
		{
			taskbar_t::hook_all(1000);
		}
	}
	else if(uMsg == WM_DESTROY)
	{
		taskbar_t::unhook(hWnd);
		taskbar_t::hook_all(1000);
	}

	return wndproc(hWnd, uMsg, wParam, lParam);
}

LRESULT __stdcall TaskbarSubclassProc(HWND hWnd, UINT uMsg, WPARAM wParam, LPARAM lParam, [[maybe_unused]] UINT_PTR uIdSubclass, DWORD_PTR dwRefData)
{
	if(uMsg == WM_CONTEXTMENU)
	{
		auto hTaskbar = reinterpret_cast<HWND>(dwRefData);
		auto pt = Point::CursorPos();
		if(taskbar_t::is_allowed_area(hTaskbar, pt))
		{
			if(ShowTaskbarContextMenu(hTaskbar, pt, wParam == 0 && lParam == 0? WM_RBUTTONDOWN : WM_CONTEXTMENU))
				return 0;			
		}
	}
	else if(uMsg == WM_MOUSEACTIVATE)
	{
		auto lret = ::DefSubclassProc(hWnd, uMsg, wParam, lParam);
		auto msg = HIWORD(lParam);

		if(/*msg != WM_LBUTTONDOWN && */msg != WM_RBUTTONDOWN)
			return lret;

		auto hTaskbar = reinterpret_cast<HWND>(dwRefData);
		auto pt = Point::CursorPos();

		if(taskbar_t::is_allowed_area(hTaskbar, pt))
		{
			int disabled_taskbar = 0;
			if(RegistryConfig::get(L"\\disable", L"taskbar", disabled_taskbar) && disabled_taskbar == 1)
				return lret;

			if(msg == WM_RBUTTONDOWN)
			{
				Keyboard kb;
				if(auto count = kb.get_keys_excloude_contextmenu(); count > 0)
				{
					if(kb.key_ctrl())
					{
						if(count == 2 && kb.key_win())
							return lret;

						if(count == 1 && !_initializer.has_error())
						{
							if(!_initializer.Status.Loaded)
								_initializer.OnState();
						}
					}
				}
			}

			if(_initializer.has_error())
			{
				if(msg != WM_RBUTTONDOWN)
					return lret;

				_initializer.OnState();

				if(_initializer.has_error())
					return lret;
			}
			else
			{
				if(_initializer.Status.Disabled)
					return lret;
			}

			if(!is_registered())
			{
				_taskbar_mouse.unhook();
				taskbar_t::unhook(hWnd);
			//	for(auto &window : _window_taskbar)
			//		window.second.remove_prop(UxSubclass);
				return lret;
			}

			if(msg == WM_RBUTTONDOWN)
			{
				_taskbar_mouse.hook(WH_MOUSE, [](int nCode, WPARAM wParam, LPARAM lParam)->LRESULT
				{
					//auto lret = _taskbar_mouse.callnext(nCode, wParam, lParam);
					if(nCode == HC_ACTION && wParam == WM_RBUTTONUP)
					{
						auto mh = reinterpret_cast<MOUSEHOOKSTRUCT *>(lParam);
						Window window = ::GetParent(mh->hwnd);
						if(window.is_prop(UxSubclass))
						{
							_taskbar_mouse.unhook();
							::SetFocus(window);
							ShowTaskbarContextMenu(window, mh->pt, WM_CONTEXTMENU);
							return 1;
						}
					}
					return _taskbar_mouse.callnext(nCode, wParam, lParam);
				}, hWnd);
				
				return MA_ACTIVATEANDEAT;
			}

			//if(msg != WM_RBUTTONDOWN)
			//	::SetFocus(hWnd);

			/*
			if(msg == WM_RBUTTONDOWN)
			{
				::SetFocus(hWnd);
				//ShowTaskbarContextMenu(hWnd, pt, WM_RBUTTONDOWN);
				SendMessageW(hWnd, WM_CONTEXTMENU, 0, 0);
			}
			*/
		}
		return lret;
	}
	else if(uMsg == WM_SETTINGCHANGE)
	{
		if(SPI_SETWORKAREA == wParam && ::GetSystemMetrics(SM_CMONITORS) > 1)
		{
			taskbar_t::hook_all(1000);
		}
	}
	else if(uMsg == WM_DESTROY)
	{
		taskbar_t::unhook(hWnd);
		taskbar_t::hook_all(1000);
	}

	return ::DefSubclassProc(hWnd, uMsg, wParam, lParam);
}

//integrate 
BOOL APIENTRY DllMain(HINSTANCE hInstance, DWORD dwReason, LPVOID)
{
	try
	{
		if(dwReason == DLL_PROCESS_ATTACH)
		{
			::DisableThreadLibraryCalls(hInstance);
			//InitCommonControls();
			/*INITCOMMONCONTROLSEX icex{};
			// Load the ToolTip class from the DLL.
			icex.dwSize = sizeof(icex);
			icex.dwICC = ICC_BAR_CLASSES;
			InitCommonControlsEx(&icex);
			*/

			_hInstance = hInstance;
			_initializer.HInstance = _hInstance;

#if _DEBUG
			// detect memory leaks
			_CrtSetDbgFlag(_CRTDBG_REPORT_FLAG
						   | _CRTDBG_CHECK_ALWAYS_DF
						   | _CRTDBG_LEAK_CHECK_DF
						   | _CRTDBG_ALLOC_MEM_DF);

			//::_CrtSetReportMode(_CRT_ERROR, _CRTDBG_MODE_DEBUG);
#endif
			_loader.init();

			if(!_loader.explorer && !_loader.path.ends_with(L"\\shell.exe"))
			{
				
				//	if(_loader.path.ends_with(L"\\firefox.exe") || _loader.path.ends_with(L"\\devenv.exe"))
				//		return 0;
				
				int disabled_3rdparty = 0;
				if(RegistryConfig::get(L"\\disable", L"3rdparty", disabled_3rdparty) && disabled_3rdparty == 1)
					return 0;

				/*if(RegistryConfig::IsFolderExtensions())
				{
					if(!hasImportTrackPopupMenu())
						return 0;
				}*/
			}

			//if(!loader)
			//	_log.info(L"Load '%s'", Path::Module(nullptr).c_str());

			if(_initializer.init(_hInstance))
			{
				// CoInitializeEx and the IGlobalOptions activation used to run
				// here. Both are COM calls under the loader lock, which is
				// documented as unsupported and is a plausible cause of the
				// Explorer-hangs-at-startup reports. They moved to
				// Initializer::ensure_com, on the thread that builds menus.

				_initializer.process.hModule = _loader.handle;
				_initializer.process.path = Path::Module(_loader.handle).move();
				_initializer.process.name = Path::Title(_initializer.process.path).move();
				_initializer.process.id = ::GetCurrentProcessId();
				_initializer.process.handle = ::GetCurrentProcess();

				//_log.info(L"%s", _initializer.process.name.c_str());

				ContextMenu::RegisterLayer();

				// Pin the module before patching anything. Once an import table
				// points at code in this DLL, the DLL can never be unloaded: the
				// patch lives in somebody else's module and nothing takes it back
				// out, so the next call through it jumps into freed memory.
				//
				// Refusing in DllCanUnloadNow is not enough, and assuming it was
				// cost a working machine. COM honours that answer, but Explorer's
				// shell-extension host caches handler DLLs and calls FreeLibrary on
				// them directly when it decides they have gone idle - it never asks.
				// Explorer duly unloaded us a few minutes after each start, and the
				// next menu call faulted at 0xc0000005 inside "shell.dll_unloaded",
				// on Explorer's own cache timer, which is why the crashes arrived
				// exactly thirty-one seconds apart.
				//
				// GET_MODULE_HANDLE_EX_FLAG_PIN makes the reference count permanent,
				// so FreeLibrary cannot unload us from any caller. This is the
				// standard treatment for a DLL that patches import tables, and it
				// belongs here rather than at any of the individual unload paths,
				// because it is the only one that covers all of them.
				HMODULE pinned{};
				::GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_PIN | GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS,
									 reinterpret_cast<LPCWSTR>(&TrackPopupMenuExProc), &pinned);

				iathook_NtUserTrackPopupMenuEx
					.init(L"user32.dll", "win32u.dll", "NtUserTrackPopupMenuEx", TrackPopupMenuExProc)
					.install();

				auto hook = []()
				{
					__trace(L"hook all the modules in '%s' process", _initializer.process.name.c_str());

					auto user32 = "user32.dll";

					// Explorer carries a few hundred modules and this runs again as
					// new ones load, so the previous per-module linear scan of the
					// hook vector was quadratic, with a full PE import table walk
					// behind every miss.
					std::unordered_set<HMODULE> hooked;
					hooked.reserve(iathook_TrackPopupMenu.size() + 64);
					for(const auto &m : iathook_TrackPopupMenu)
						hooked.insert(m._hModule);

					// hook all the modules in this process.
					for(auto hModule : Process::Modules(_initializer.process.handle))
					{
						if(_hInstance == hModule)
							continue;

						if(!hooked.insert(hModule).second)
							continue;

						iathook_TrackPopupMenu.emplace_back(hModule, user32, ::TrackPopupMenu, TrackPopupMenuProc).install();
						iathook_TrackPopupMenu.emplace_back(hModule, user32, ::TrackPopupMenuEx, TrackPopupMenuExProc).install();
					}
				};

				//_TrackPopupMenu.init(::TrackPopupMenu, TrackPopupMenuProc).hook();
				//_TrackPopupMenuEx.init(::TrackPopupMenuEx, TrackPopupMenuExProc).hook();
				//_CoCreateInstance.init(::CoCreateInstance, CoCreateInstanceProc).hook();
				
				if(_loader.explorer)
				{
					//_log.info(_loader.path);

					_CoCreateInstance.Begin();
					//_DllGetClassObject.init(hModule, "DllGetClassObject", DllGetClassObjectHook).hook();
					_CoCreateInstance.init(::CoCreateInstance, CoCreateInstanceHook).hook();
					//auto m = &_detours_ci[hModule];
					//if(!m->installed())
					//m->init(hModule, "api-ms-win-core-com-l1-1-0.dll", ::CoCreateInstance, CoCreateInstanceProc).install();
					_CoCreateInstance.Commit();

					if(!iathook_NtUserTrackPopupMenuEx.installed())
					{
						std::thread([=]() { ::Sleep(2000); hook(); }).detach();
					}

					if(ver->IsWindows11OrGreater())
					{

						/*
						auto keyCLSID = Registry::ClassesRoot.OpenSubKey(L"CLSID\\" CLS_FileExplorerContextMenu "\\TreatAs", false, false);
						if(!(keyCLSID && keyCLSID.GetString(nullptr).equals(CLS_ContextMenu)))
						{
							auto hModule = ::GetModuleHandleW(Windows_UI_FileExplorer);

							if(!hModule)
								hModule = ::LoadLibraryW(Windows_UI_FileExplorer);

							if(hModule)
							{
								auto r = _CoCreateInstance.Begin();
								_log.info(L"%x", r);
								//_DllGetClassObject.init(hModule, "DllGetClassObject", DllGetClassObjectHook).hook();
								_CoCreateInstance.init(::CoCreateInstance, CoCreateInstanceHook).hook();
								//auto m = &_detours_ci[hModule];
								//if(!m->installed())
								//m->init(hModule, "api-ms-win-core-com-l1-1-0.dll", ::CoCreateInstance, CoCreateInstanceProc).install();
								_CoCreateInstance.Commit();
							}
						}
						keyCLSID.Close();
						*/

						taskbar_t::hook_all(1000);
					}
				}
				else if(!iathook_NtUserTrackPopupMenuEx.install())
				{
					hook();
				}
			}
			//IsRegistered
			/*
			IID iid{};
			CLSIDFromString(L"{23170F69-40C1-278A-1000-000100020000}", &iid);
			Guid guid = iid;
			MB(guid.to_string(2).c_str());
			*/
			//UuidFromStringW

			return TRUE;
		}
		else if(dwReason == DLL_PROCESS_DETACH)
		{
			if(!is_registered())
			{
				if(_loader.explorer)
				{
					// Perform any necessary cleanup.
					_taskbar_mouse.unhook();
					taskbar_t::unhook_all();
					//detour_NtUserTrackPopupMenuEx.uninstall(true);

					if(ver->IsWindows11OrGreater())
					{
						_CoCreateInstance.Begin();
						//_DllGetClassObject.unhook();
						_CoCreateInstance.unhook();
						_CoCreateInstance.Commit();
					}
				}

				for(auto &d : iathook_TrackPopupMenu)
					d.uninstall(true);

				//_TrackPopupMenu.unhook();
				//_TrackPopupMenuEx.unhook();
				//_CoCreateInstance.unhook();

				ContextMenu::UnRegisterLayer();
			}

			taskbar_t::_IUIAutomation.release();

			_log.close();

			//::SendNotifyMessageW(HWND_BROADCAST, WM_NULL, 0, 0);	

			return TRUE;
		}
	}
	catch(...) // handle all exceptions
	{
#ifdef _DEBUG
		_log.exception(__func__);
		_log.close();
#endif
	}
	return FALSE;
}

//IID_FolderExtensions
//#pragma comment(linker, "/export:DllGetClassObject=DllGetClassObject")
_Check_return_
STDAPI DllGetClassObject(_In_ REFCLSID rclsid, [[maybe_unused]] _In_ REFIID riid, [[maybe_unused]] _Outptr_ LPVOID FAR *ppv)
{
	auto hr = E_NOTIMPL;// CLASS_E_CLASSNOTAVAILABLE,E_NOTIMPL, E_OUTOFMEMORY, and E_UNEXPECTED,E_INVALIDARG
	Guid iid = rclsid;
	//Guid iid2 = riid;
	if(ppv) *ppv = nullptr;

	__try
	{
		if(iid.equals(IID_FolderExtensions))
			return E_NOTIMPL;

		if(!iid.equals({ IID_ContextMenu, IID_IconOverlay }))
			return hr;

		if(Initializer::Status.Disabled)
			return hr;

		if(!is_registered())
			return hr;
		
		if(_initializer.has_error())
			return hr;
		
		if(rclsid == IID_ContextMenu)
		{
			_loader.contextmenuhandler = true;
			Selections::point.GetCursorPos();
		}

		if(!_initializer.Status.Loaded)
			_initializer.init();
	}
	except
	{
#ifdef _DEBUG
		_log.exception(__func__);
#endif
	}
	_log.close();

	// Hand out a real class factory for the context-menu CLSID. Until now this
	// returned E_NOTIMPL on every path and the registration existed only to get
	// the DLL loaded, which meant every host that is not Explorer lost its
	// selection: Selections::QuerySelected reaches it through IShellBrowser, and
	// a third-party file manager does not provide one. The host was already
	// offering us the selection through IShellExtInit and we were declining it.
	//
	// The object inserts no items, so Explorer's menu is unchanged - the hook
	// still does all the work there. See Include\ShellExt.h.
	//
	// Constructed out of line: this function wraps its body in __try, and MSVC
	// rejects __try in a function that also needs object unwinding (C2712).
	if(hr == E_NOTIMPL && rclsid == IID_ContextMenu && ppv)
		hr = CreateShellExtFactory(riid, ppv);

	return hr;
}

//DllCanUnloadNow. COM calls this function to determine whether the object is serving any clients. 
//If not, the system can unload the DLL and free the associated memory.
// Check if we can unload the component from the memory.
// NOTE: The component can be unloaded from the memory when its reference 
// count is zero (i.e. nobody is still using the component).
//#pragma comment(linker, "/export:DllCanUnloadNow=DllCanUnloadNow")
__control_entrypoint(DllExport)
STDAPI DllCanUnloadNow(void)
{
	// Never while the import tables are still patched, and this test comes first
	// because it is the one that crashes machines.
	//
	// The IAT hooks are written into OTHER modules' import tables, and nothing
	// removes them when the product is unregistered. Unloading while they are
	// installed leaves those entries pointing into freed memory, and the next
	// menu jumps there. Observed, not theorised: with a running Explorer holding
	// the DLL, unregistering made is_registered() false, the check below then
	// answered S_OK, COM unloaded us, and explorer.exe faulted at 0xc0000005 in
	// "shell.dll_unloaded" every thirty seconds - it could not open a window,
	// because every attempt went through a hooked entry point. This is a strong
	// candidate for the upstream reports of Explorer restart loops.
	//
	// Once hooked, this DLL stays for the life of the process. Unloading is only
	// safe if the hooks are removed first, and the teardown to do that does not
	// exist yet.
	if(iathook_NtUserTrackPopupMenuEx.installed())
		return S_FALSE;

	for(const auto &h : iathook_TrackPopupMenu)
	{
		if(h.installed())
			return S_FALSE;
	}

	// Anything we handed out also pins us. DllGetClassObject used to return
	// E_NOTIMPL and never produced an object; now that it returns a real class
	// factory, answering S_OK with a live IContextMenu outstanding would let COM
	// unload the DLL out from under the host still holding it.
	if(com_object_count.load(std::memory_order_relaxed) > 0)
		return S_FALSE;

	if(!_loader.explorer || !is_registered())
		return S_OK;
	return S_FALSE;
	/*
	if(ContextMenu::Processes.size() == 0)
	{
		int p = 0;
		EnumThreadWindows(GetCurrentThreadId(), [](HWND, LPARAM lp) {
		(*((int *)lp))++;
			return 0;
		}, (LPARAM)&p);

		//if(p)MBF(L"%d", p);
		return p > 0 ? S_FALSE : S_OK;
	}

	//if(_loader.explorer)
	//	return release() ? S_OK : S_FALSE;
	return ContextMenu::Processes.size() == 0 ? S_OK : S_FALSE;
	//return S_OK;
	*/
}

// Register the COM server and the context menu handler.
HRESULT Register(bool reg)
{
	try
	{
		if(reg)
		{
			Path::Delete(_log.path());
			//_log.reset();
		}

		if(!ver->IsWindows7OrGreater())
		{
			//windows compatibility
			_log.error(L"%s", string::Extract(_hInstance, IDS_WINDOWS_COMPATIBILITY).c_str());
			return ERROR_EXE_MACHINE_TYPE_MISMATCH;//ERROR_DS_VERSION_CHECK_FAILURE
		}

		auto is_elevated = Security::Elevation::IsElevated();

		if(!is_elevated)
		{
			// Missing administrative privileges!
			string msg = string::Extract(_hInstance, IDS_ADMIN_PRIVILEGES).move();
			//You will need to provide administrator permission to run this Shell
			_log.error(L"%s", msg.c_str());
			return ERROR_ACCESS_DENIED;
		}

		string path = Path::Module(_hInstance).move();

		if(reg)
		{
			string dir = Path::Parent(path).move();
			if(!dir.empty())
				Security::Permission::SetFile(dir.c_str());
			//_log.reset();
			//IO::Path::Delete(_log.path());
		}

		string msg;

		if(reg)
		{
			//_log.create();
			REGOP regop;
			regop.REGISTER = regop.CONTEXTMENU = regop.ICONOVERLAY = true;

			if(!RegistryConfig::Register(path, regop))
			{
				msg = string::Extract(_hInstance, IDS_REGISTER_NOT_SUCCESS).move();
				_log.error(L"%s", msg.c_str());
				return S_FALSE;
			}
			msg = string::Extract(_hInstance, IDS_REGISTER_SUCCESS).move();
		}
		else
		{
			if(!RegistryConfig::IsRegistered())
				return S_OK;

			if(!RegistryConfig::Unregister())
			{
				msg = string::Extract(_hInstance, IDS_UNREGISTER_NOT_SUCCESS).move();
				_log.error(L"%s", msg.c_str());
				return S_FALSE;;
			}
			msg = string::Extract(_hInstance, IDS_UNREGISTER_SUCCESS).move();
		}

		_log.info(L"%s", msg.c_str());

		_log.close();

		return S_OK;
	}
	catch(...)
	{
#ifdef _DEBUG
		_log.exception(__func__);
#endif
	}
	_log.close();
	return S_FALSE;
}
/*
//  Register the COM server and the context menu handler.
__control_entrypoint(DllExport)
STDAPI DllRegisterServer()
{
	return Register(true);
}

__control_entrypoint(DllExport)
STDAPI DllUnregisterServer()
{
	return Register(false);
}
*/
/*
STDAPI DllInstall(BOOL bInstall, _In_opt_ PCWSTR pszCmdLine)
{
	MBF(L"%d %s", bInstall, pszCmdLine);
	return E_NOTIMPL;
}
*/

/*
#include <Shldisp.h>

CoInitialize(NULL);
// Create an instance of the shell class
IShellDispatch4 *pShellDisp = NULL;
HRESULT sc = CoCreateInstance(CLSID_Shell, NULL, CLSCTX_SERVER, IID_IDispatch, (LPVOID *) &pShellDisp );
// Show the desktop
sc = pShellDisp->ToggleDesktop();
// Restore the desktop
sc = pShellDisp->ToggleDesktop();
pShellDisp->Release();
 */

#pragma endregion

uint32_t ImmersiveColor::GetColorByColorType(uint32_t colorType)
{
	auto colorSet = GetImmersiveUserColorSetPreference(false, false);
	return GetImmersiveColorFromColorSetEx(colorSet, colorType, false, 0);
}

uint32_t ImmersiveColor::GetColorByName(const wchar_t *name)
{
	auto colorSet = GetImmersiveUserColorSetPreference(false, false);
	auto colorType = GetImmersiveColorTypeFromName(name);
	return GetImmersiveColorFromColorSetEx(colorSet, colorType, false, 0);
}

uint32_t ImmersiveColor::GetImmersiveUserColorSetPreference(bool bForceCheckRegistry, bool bSkipCheckOnFail)
{
	return DLL::Invoke<uint32_t>(hUxTheme, 98, bForceCheckRegistry, bSkipCheckOnFail);
}

uint32_t ImmersiveColor::GetImmersiveColorFromColorSetEx(uint32_t dwImmersiveColorSet, uint32_t dwImmersiveColorType, bool bIgnoreHighContrast, uint32_t dwHighContrastCacheMode)
{
	return DLL::Invoke<uint32_t>(hUxTheme, 95, dwImmersiveColorSet, dwImmersiveColorType, bIgnoreHighContrast, dwHighContrastCacheMode);
}

uint32_t ImmersiveColor::GetImmersiveColorTypeFromName(const wchar_t *name)
{
	return DLL::Invoke<uint32_t>(hUxTheme, 96, name);
}

uint32_t ImmersiveColor::GetImmersiveColorSetCount()
{
	return DLL::Invoke<uint32_t>(hUxTheme, 94);
}

bool ImmersiveColor::IsSupported()
{
	return  ::IsCompositionActive() && DLL::IsFunc(hUxTheme, 95);
}
