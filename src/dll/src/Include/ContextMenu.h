#pragma once

//constexpr auto WC_MENU_Layer = L"Nilesoft.Shell.Window.Layers";
//constexpr auto WC_MENU_Layers = L"Nilesoft.Shell.Window.Border";
//constexpr auto WC_MENU_Layers = L"Nilesoft.Shell.Window.Shadow";
// Process-global. Upstream registers "Nilesoft.Shell.Window" in the same
// process, and RegisterClassW fails on a duplicate name, so this must differ.
constexpr auto WC_Shell_Window = L"TCNO.Shell.Window";
constexpr auto def_COMSPEC = L"ComSpec";
constexpr auto def_EXPLORER = L"explorer.exe";
constexpr auto def_POWERSHELL = L"powershell.exe";
constexpr auto def_PWSH = L"pwsh.exe";
// Window property name, resolved through the global atom table. Sharing
// upstream's bare "UxSubclass" would mean both builds reading and clobbering
// each other's saved WNDPROC on the same taskbar windows.
constexpr auto UxSubclass = L"TCNO.Shell.UxSubclass";
constexpr auto Windows_UI_FileExplorer = L"Windows.UI.FileExplorer.dll";

#include "Include/Theme.h"
#include <Library/PlutoVGWrap.h>
#include "Include/Tip.h"
#include <stack>

#define MF_ALLSTATE         0x00FF
#define MF_MAINMENU         0xFFFF
#define MFMWFP_OFFMENU      0
#define MFMWFP_MAINMENU     0x0000FFFF
#define MFMWFP_NOITEM       0xFFFFFFFF
#define MFMWFP_UPARROW      0xFFFFFFFD  //Warning: Also used to define IDSYS_MNUP
#define MFMWFP_DOWNARROW    0xFFFFFFFC  //Warning: Also used to define IDSYS_MNDOWN
#define MFMWFP_MINVALID     0xFFFFFFFC
#define MFMWFP_ALTMENU      0xFFFFFFFB
#define MFMWFP_FIRSTITEM    0

#define MNUS_DEFAULT      0x00000001
#define MNUS_DELETE       0x00000002
#define MNUS_DRAWFRAME    0x00000004

// This tells xxxMNItemSize that the bitamp size is not avilable
#define MNIS_MEASUREBMP -1


//MN_SIZEWINDOW wParam flag. xxxMNUpdateShownMenu sends this message, so keep MNSW_ and MNUS_ in sync.

#define MNSW_RETURNSIZE  0
#define MNSW_SIZE        MNUS_DEFAULT
#define MNSW_DRAWFRAME   MNUS_DRAWFRAME

//
// System timer IDs
//
#define IDSYS_LAYER         0x0000FFF5L
#define IDSYS_FADE          0x0000FFF6L
#define IDSYS_WNDTRACKING   0x0000FFF7L
#define IDSYS_FLASHWND      0x0000FFF8L
#define IDSYS_MNAUTODISMISS 0x0000FFF9L
#define IDSYS_MOUSEHOVER    0x0000FFFAL
#define IDSYS_MNANIMATE     0x0000FFFBL
#define IDSYS_MNDOWN        MFMWFP_DOWNARROW // 0xFFFFFFFC
#define IDSYS_LBSEARCH      0x0000FFFCL
#define IDSYS_MNUP          MFMWFP_UPARROW   // 0xFFFFFFFD
#define IDSYS_STANIMATE     0x0000FFFDL
#define IDSYS_MNSHOW        0x0000FFFEL
#define IDSYS_SCROLL        0x0000FFFEL
#define IDSYS_MNHIDE        0x0000FFFFL
#define IDSYS_CARET         0x0000FFFFL


//EXTERN_C LRESULT CALLBACK TaskBarSubclassProc(HWND hWnd, UINT uMsg, WPARAM wParam, LPARAM lParam);

LRESULT WINAPI LayerProc(HWND hWnd, UINT Msg, WPARAM wParam, LPARAM lParam);

//EXTERN_C LRESULT __stdcall TaskBarSubclassProc(HWND hWnd, UINT uMsg, WPARAM wParam, LPARAM lParam, UINT_PTR uIdSubclass, DWORD_PTR dwRefData);

//#include <stack>
namespace Nilesoft
{
	namespace Shell
	{
		// Subclass id, paired with our own SUBCLASSPROC. Changed from upstream's
		// 0x1E34270F so the two builds cannot collide on a shared window.
		constexpr auto NILESOFTSHELL = 0x7C0A5E31U;
		static const uintptr_t CONTEXTMENUSUBCLASS = NILESOFTSHELL;
		static const uintptr_t CONTEXTMENUSUBCLASS_TASKBAR = NILESOFTSHELL + 1;

		struct menuitem_t
		{
			uint32_t type = 0;
			uint32_t wid = 0;
			uint32_t hash = 0;
			MUID *ui = nullptr;
			string name;
			string title;
			string keys;
			uint32_t length = 0;
			int tab = 0;
			bool disabled = false;
			bool radio_check = false;
			int checked = 0;
			ULONG_PTR dwItemData = 0;
			HBITMAP image = nullptr;
			menuitem_t *parent = nullptr;
			string path;
			Position position = Position::Auto;
			Visibility visibility = Visibility::Enabled;
			std::vector<NativeMenu*> native_items;
			std::vector<menuitem_t *> items;
			bool is_toplevel = false;
			~menuitem_t()
			{
				for(auto item : items)
					delete item;
			}

			bool is_separator() const { return type == 2; }
			bool is_menu() const { return type == 1; }

			uint32_t uid() const { return ui ? ui->id : hash; }
		};

		struct WND
		{
			struct window_t
			{
				HWND handle{};
				Rect rect;

				long x{};
				long y{};
				long width{};
				long height{};
				bool visible{};
				HBITMAP hbitmap{};

				void destroy()
				{
					if(handle)
						::DestroyWindow(handle);
					if(hbitmap)
						::DeleteObject(hbitmap);
					handle = {};
					hbitmap = {};
				}

				bool create(long x, long y, long width, long height, HWND hOwner, uint32_t ex_style = 0)
				{
					handle = ::CreateWindowExW(WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_TRANSPARENT | WS_EX_NOACTIVATE | ex_style,
											   WC_Shell_Window, nullptr, WS_POPUP,
											   x, y,
											   width, height,
											   hOwner, nullptr, Path::GetCurrentModule(), nullptr);
					return handle;
				}

				bool regoin(uint8_t radius = 0) const {
					return WND::Regoin(handle, 0, 0, width + 1, height + 1, radius);
				}
			};

			window_t layer;
			window_t blurry;

			HWND handle{};
			HDC hdc{};
			Rect rect;
			HMENU hMenu{};
			//CriticalSection cs;
			bool visible_layers = false;
			long x{};
			long y{};
			long width{};
			long height{};
			bool visible = true;
			bool has_scroll = false;
			bool scrolled = false;
			bool de = true;
			HBITMAP hbitmap{};
			ContextMenu *ctx{};

			HWND dr = 0;

			WND(HWND hWnd = nullptr) : handle{ hWnd }
			{
				//cs.lock();
			}

			void destroy()
			{
				//cs.unlock();
				blurry.destroy();
				layer.destroy();
				if(hbitmap) ::DeleteObject(hbitmap);
				if(hdc) ::ReleaseDC(handle, hdc);
				hbitmap = {};
				handle = {};
			}

			bool show_layers()
			{
				if(!visible_layers)
				{
					// SWP_NOOWNERZORDER = Does not change the owner window's position in the Z order. 
					// SWP_NOZORDER = Retains the current Z order (ignores the hWndInsertAfter parameter). 
					// | SWP_NOSENDCHANGING | SWP_NOCOPYBITS | SWP_NOREDRAW
					auto flags = SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOOWNERZORDER | SWP_NOREDRAW | SWP_NOACTIVATE | SWP_SHOWWINDOW;

					auto hWinPosInfo = ::BeginDeferWindowPos((layer.handle != nullptr) + (blurry.handle != nullptr));
					if(hWinPosInfo)
					{
						if(layer.handle)
						{
							hWinPosInfo = ::DeferWindowPos(hWinPosInfo, layer.handle, nullptr, 0, 0, 0, 0, flags);
							layer.visible = true;
						}

						if(blurry.handle)
						{
							hWinPosInfo = ::DeferWindowPos(hWinPosInfo, blurry.handle, nullptr, 0, 0, 0, 0, flags);
							blurry.visible = true;
						}

						if(hWinPosInfo)
							::EndDeferWindowPos(hWinPosInfo);

						::SetWindowPos(handle, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOOWNERZORDER |SWP_NOREDRAW | SWP_NOACTIVATE | SWP_SHOWWINDOW);
						//::ShowWindowAsync(handle, SW_HIDE);
					}

					visible_layers = layer.visible || blurry.visible;
				}
				return visible_layers;
			}

			bool regoin(uint8_t radius = 0) const {
				return Regoin(handle, 0, 0, width + 1, height + 1, radius);
			}

			bool set_prop() {
				return ::SetPropW(handle, L"wnd", this);
			}

			static WND *get_prop(HWND hWnd) {
				return (WND *)::GetPropW(hWnd, L"wnd");
			}

			static bool Regoin(HWND hWnd, int x, int y, int width, int height, int radius = 0)
			{
				radius += radius + (radius >= 8 ? 2 : 1);
				auto ret = false;
				HRGN hRegion{};
				if(radius > 0)
					hRegion = ::CreateRoundRectRgn(x, y, width, height, radius, radius);
				else
					hRegion = ::CreateRectRgn(x, y, width, height);

				if(hRegion)
				{
					ret = ::SetWindowRgn(hWnd, hRegion, 0);
					::DeleteObject(hRegion);
				}
				return ret;
			}
		};

		/*
plutovg_move_to(pluto, start.x, start.y);
			plutovg_line_to(pluto, end.x, end.y);
			plutovg_set_source_rgb(pluto, color_branch.r / 255.0,
								   color_branch.g / 255.0,
								   color_branch.b / 255.0);
			plutovg_set_line_width(pluto, width_delta_stack[sp] > line_width
											  ? width_delta_stack[sp]
											  : line_width);
			plutovg_stroke(pluto);


	plutovg_surface_t *const pluto_surface =
		plutovg_surface_create(IMG_SIZE, IMG_SIZE);
	plutovg_t *const pluto = plutovg_create(pluto_surface);

	// Add background to image.
		plutovg_gradient_t *const gradient = plutovg_gradient_create_linear(
			IMG_SIZE / 2U, 0U, IMG_SIZE / 2U, IMG_SIZE);
		for(uint8_t stop_idx = 0U; stop_idx < sizeof(stops) / sizeof(stops[0]);
			++stop_idx)
		{
			plutovg_gradient_add_stop_rgb(
				gradient, stops[stop_idx], colors[stop_idx].r / 255.0,
				colors[stop_idx].g / 255.0, colors[stop_idx].b / 255.0);
		}
		plutovg_rect(pluto, 0U, 0U, IMG_SIZE, IMG_SIZE);
		plutovg_set_source_gradient(pluto, gradient);
		plutovg_fill(pluto);
		*/


		class ContextMenu
		{
		public:
			//size_t cbsize = sizeof(ContextMenu);
			struct Prop
			{
				static bool Set(HWND handle, ContextMenu *ctx)
				{
					return ::SetPropW(handle, CLS_Shell, ctx);
				}

				template<typename T = ContextMenu *>
				static T Get(HWND handle)
				{
					return reinterpret_cast<T>(::GetPropW(handle, CLS_Shell));
				}

				static bool Remove(HWND handle)
				{
					return handle ? ::RemovePropW(handle, CLS_Shell) : false;
				}
			};

			struct menu_t
			{
				enum {
					MFT_UNDEFINED = -1,
					MFT_SYSTEM = 0,
					MFT_DYNAMIC = 1
				};

				HMENU handle{};
				uint32_t id{};
				uint32_t hash{};

				int level = -1;
				int type = -1;
				bool is_main{};
				bool destory{};
				bool has_col{};
				HWND wnd{};
				MenuItemInfo *owner{};
				long popup_height{};
				string path;

				std::vector<MenuItemInfo *> statics;
				std::vector<NativeMenu *> dynamics;

				std::vector<menuitem_t *> *std_items = nullptr;

				NativeMenu *parent{};
				//bool dynamic{};

				struct
				{
					uint32_t id{};
					uint32_t length{};
					long width{};
					long height{};
					//uint16_t dispaly = 0;
					uint16_t images{};
					uint16_t checks{};
					uint16_t popups{};
					bool has_tap{};
					bool has_align() const  { return checks || images; }
				} draw;

				bool is_dynamic() const
				{
					return owner ? owner->dynamic : false;
				}
			};

			struct PositionList
			{
				std::vector<MenuItemInfo*> Top;
				std::vector<MenuItemInfo*> Middle;
				std::vector<MenuItemInfo*> Bottom;
				std::vector<MenuItemInfo*> Auto;
				std::vector<MenuItemInfo*> Custom;

				void push(auto item)
				{
					switch(item->position)
					{
						case Position::Top:
							Top.push_back(item);
							break;
						case Position::Middle:
							Middle.push_back(item);
							break;
						case Position::Bottom:
							Bottom.push_back(item);
							break;
						case Position::Auto:
						case Position::None:
							Auto.push_back(item);
							break;
						default:
							Custom.push_back(item);
							break;
					}
				};

				auto size() const { return Top.size() + Middle.size() + Bottom.size() + Auto.size() + Custom.size(); }

				static bool is_id(uint32_t id, const MenuItemInfo *item) {
					return item && item->hash == id;
				}
			};

			struct ID
			{
				//0x03000012
				//static constexpr auto Sys = (0xffffffff - 0x00000fff);
				//static constexpr auto Max = (0xffffffff - 0x00000fff);
				//static constexpr auto Min = (0xffffffff - 0x0000ffff);
				//static constexpr auto Start = (0xffffffff - 0x0000ffffu); //65535
				//firstUniqueID
				//60007
				static constexpr auto start_id = 0x0fffffff; //0-65535
				static constexpr auto start_sys = 0x5fffffff;

				uint32_t sys = start_sys;
				uint32_t id = start_id;

				uint32_t get_id() { return id++; }
				uint32_t get_sys() { return sys++; }

				bool equals(uint32_t ident) const
				{
					return(ident >= start_id && ident < start_sys);
				}

			} ident;

		public:
			ContextMenu(const ContextMenu &) = delete;
			ContextMenu(HWND hWnd, HMENU hMenu, Point const &pt);
			~ContextMenu();

		public:
			/*
			// system window1
			CabinetWClass
			(null)
			#32769
			CabinetWClass
			CabinetWClass

			// system window2
			WorkerW
			CabinetWClass
			CabinetWClass
			CabinetWClass
			CabinetWClass

			// system window3
			ReBarWindow32
			WorkerW
			WorkerW
			CabinetWClass
			CabinetWClass


			---------------
			//column options menu
			DirectUIHWND
			SHELLDLL_DefView
			SHELLDLL_DefView
			CabinetWClass
			CabinetWClass


			---------------------------
			// back menu
			TravelBand
			ReBarWindow32
			ReBarWindow32
			CabinetWClass
			CabinetWClass

			---------------------------
			// Breadcrumb menu
			Breadcrumb Parent
			msctls_progress32
			msctls_progress32
			CabinetWClass
			CabinetWClass


			win10->taskbar->datetime
			Shell_Trayind
			(null)
			#32769
			Shell_Trayind
			Shell_Trayind

			win10->taskbar->start
			LauncherTipWnd
			(null)
			#32769
			LauncherTipWnd
			LauncherTipWnd

			// remove properties
			DirectUIHWND
			DUIViewWndClassName
			DUIViewWndClassName
			CabinetWClass
			CabinetWClass
			*/

			// save screenshots
			struct ss_t
			{
				HBITMAP hbitmap;
				Rect rc;
			};
			std::vector<ss_t> _level_bitmap;

			struct {
				HWND owner{};
				HWND active{};
				HWND focus{};
			}hwnd;

			struct {
				bool activated{};
				bool DwmEnabled{};
				explicit operator bool() const { return DwmEnabled && activated; }
			} composition;

			struct {
				HFONT handle{};
				LOGFONTW menu{};
				Font icon;
				Font icon10;
			}font;

			struct symbole_tag 
			{
				SIZE size{};
				HBITMAP normal{};
				HBITMAP normal_disabled{};
				HBITMAP select{};
				HBITMAP select_disabled{};

				~symbole_tag()
				{
					if(normal) ::DeleteObject(normal);
					if(normal_disabled) ::DeleteObject(normal_disabled);
					if(select) ::DeleteObject(select);
					if(select_disabled) ::DeleteObject(select_disabled);
				}
			};

			struct {
				symbole_tag chevron;
				symbole_tag checked;
				symbole_tag bullet;
			}symbol;
			
			struct {

				struct {
					bool enabled = true;
					bool title = true;
					bool visibility = true;
					bool parent = true;
					bool separator = true;
					bool keys = true;
					int image = 1;
					int position = 1;
					
					struct
					{
						bool duplicate = false;
						bool disabled = false;
						bool separator = false;
					}remove;

				} modify_items;

				struct {
					bool enabled = true;
					bool image = true;
					bool keys = true;
				} new_items;

			} _settings;

			struct
			{
				HWND hWnd{};
				HMENU hMenu{};
				menu_t *menu{};
				//uint32_t level{};
				uint32_t selectitem_pos = MF_NOITEM;//SELECTITEM
				MenuItemInfo *selectitem{};
				MenuItemInfo *select_previtem{};
				MenuItemInfo *tip{};
				RECT rect{};
				HDC hdc{};
				uint32_t selectid{};

				void zero()
				{
					hWnd = {};
					hMenu = {};
					menu={};
					//level = 0;
					selectitem_pos = MF_NOITEM;
					selectitem = {};
					select_previtem = {};
					selectid = {};
					hdc = {};
				}

			} current;

			struct oooo
			{
				HMENU hmenu{};
				HWND hwnd{};
				HWND hdc{};
			};

			std::unordered_map<HMENU, oooo> map_menu_wnd;

			uint8_t mouse_button = 0;
			uint32_t selectid = 0;
			Keyboard keyboard;
			Context _context;
			Window _window;
			MESSAGE msg{};

			DPI dpi;
			bool common = true;
			CACHE *_cache{};
			Visibility _vis = Visibility::Normal;

			std::vector<uint32_t> parent_level;
			struct 
			{
				std::vector<MenuItemInfo *> statics;
				std::vector<MenuItemInfo *>	dynamics;
			}
			_moved_items;

			MenuItemInfo *invoke_item{};
			std::vector<MenuItemInfo *> _items;
			std::vector<MenuItemInfo *> _items_command;
			std::vector<MenuItemInfo *> _items_popup;

			std::vector<MenuItemInfo *> _main_popup;
			std::unordered_map<HMENU, menu_t> _menus;

			WinEventHook _winEventHook;
			WindowsHook _keyboardHook;
			WindowSubclass _windowSubclass;

			Theme _theme;
			HMENU _hMenu = nullptr;
			HMENU _hMenu_original = nullptr;
			HTHEME _hTheme{};
			HBRUSH _hbackground{};
			HBRUSH _hbackground0{};
			HCURSOR hCursor{};
			uint32_t _showdelay[2]{ UINT32_MAX, UINT32_MAX };
			Rect _rcMonitor{};
			LANGID languageId = 0;
			int is_layoutRTL = 0;
			Tip _tip;
			string _screenshot;

			HINSTANCE hInstance{};
			Selections Selected;

			DWORD ProcessId{};
			DWORD ThreadId{};

			std::vector<WND *> _level;
			std::unordered_map<HWND, WND> _map;
			GC<MenuItemInfo> _gc;
			bool _uninitialized = false;

			menuitem_t *__system_menu_tree = nullptr;
			std::unordered_map<uint32_t, menuitem_t *> __map_system_menu;

			std::vector<menuitem_t *> __movable_system_items;

			// Items displaced from the tree by duplicate removal. They are freed at
			// Uninitialize rather than at the point of replacement, because
			// __map_system_menu still holds keys for the displaced node and every
			// submenu beneath it, and build_main_system_menuitems dereferences
			// whatever it finds there. Freeing on the spot turned a leak into a
			// write through a dangling pointer.
			std::vector<menuitem_t *> __replaced_system_items;

			// Owner-draw traffic actually received, so "the menu is drawn but empty"
			// can be told apart from "the menu was never asked to be drawn". USER32
			// sends WM_MEASUREITEM and WM_DRAWITEM to the menu's OWNER window, which
			// is the window WindowSubclassProc is attached to - not the popup - so a
			// host whose owner window does not deliver them produces a correctly
			// sized, correctly populated, completely unpainted menu.
			uint32_t _n_measureitem{};
			uint32_t _n_drawitem{};

			// Draws that could not be matched to one of our items and were handed
			// back to the host. get_item requires the menu handle AND the id to
			// match, so recording both sides of the first failure says which of the
			// two is wrong - and in a host whose menu owner is a hidden window, the
			// host draws nothing, which is why the rows come out blank.
			uint32_t _n_passthrough{};
			uint32_t _pt_id{};
			HMENU _pt_menu{};
			HMENU _pt_first_item_menu{};

			// Sampled while drawing, not at teardown. Uninitialize closes the theme
			// handle before it logs, so the hTheme it reported was always null and
			// said nothing about either a working or a broken menu.
			//
			// Everything reaching a composited popup depends on alpha: black is the
			// transparency colour, so a row drawn with no alpha is not a blank row,
			// it is a hole. These separate "never asked to draw it" from "drew it
			// and it did not stick":
			//   _dbg_theme     - the handle actually passed to DrawThemeTextEx
			//   _dbg_text_hr   - what that call returned, first failure kept
			//   _dbg_buffered  - whether BeginBufferedPaint gave us its own DC
			//   _n_drawstring* - text drawn, versus skipped for alpha 0
			//   _n_drawimage   - icons blitted, which bypass the theme entirely
			// Where the first row was told to draw, against where the popup
			// actually is. Every GDI call can succeed and still be clipped away
			// if the two do not overlap, which looks exactly like a menu that
			// refused to paint.
			RECT _dbg_rc_item{};
			RECT _dbg_rc_popup{};
			LONG_PTR _dbg_popup_ex{};
			bool _dbg_have_rc{};

			// Whether this instance initialized the buffered paint API, so the
			// matching uninit only runs when it did.
			bool _buffered_paint{};

			uint32_t _dbg_px_item{}, _dbg_px_wnd{};
			uint32_t _dbg_pa_item{}, _dbg_pa_wnd{};
			uint32_t _dbg_blt{};
			uint32_t _dbg_dctype{};
			RECT _dbg_clip{};
			int _dbg_clipres{};
			bool _dbg_have_px{};

			// -1 until the switch has been read once; reading the registry on every
			// selection change would put a hive lookup in the mouse path.
			int _diag_forcepaint{ -1 };

			// What the popup itself is asked to do after the first paint.
			uint32_t _n_mn_selectitem{};
			uint32_t _n_mousemove{};
			uint32_t _n_wm_paint{};
			uint32_t _n_wm_erase{};

			HTHEME _dbg_theme{};
			long _dbg_text_hr{ 1 };
			uint32_t _n_drawstring{};
			uint32_t _n_drawstring_skipped{};
			uint32_t _n_drawimage{};
			bool _dbg_buffered{};

		public:// functions

			bool set_prop(auto hWnd) { return Prop::Set(hWnd, this); }
			ContextMenu *get_prop(auto hWnd) { return Prop::Get(hWnd); }

			void init_cfg();
			bool prepare_new_items(PositionList &posList, const std::vector<NativeMenu *> &list, MenuItemInfo *owner, menu_t *menu, bool moved = false);
			bool prepare_system_items(PositionList &list, menu_t *menu);
			bool prepare_system_items2(PositionList &list, menu_t *menu);

			void prepare_system_item(menuitem_t *item, MenuItemInfo *mii, menu_t *menu);


			LRESULT OnTimer(UINT_PTR nIDEvent, TIMERPROC Timerproc = nullptr);
			LRESULT OnStart();
			LRESULT OnEnd();

			LRESULT OnInitMenu(HMENU hMenu);
			LRESULT OnInitMenuPopup(HMENU hMenu, uint32_t uPosition);
			LRESULT OnUninitMenuPopup(HMENU hMenu);
			LRESULT OnMenuSelect(HMENU hMenu, uint32_t id, uint32_t flags);
			LRESULT OnDrawItem(DRAWITEMSTRUCT *di);
			LRESULT OnMeasureItem(MEASUREITEMSTRUCT *mi);


			uint32_t invoke(CommandProperty *cmd_prop);
			bool is_excluded();
			bool Initialize();
			int Uninitialize();
			int InvokeCommand(int id);	
			void build_system_menuitems(HMENU hMenu, menuitem_t *menu, bool is_root = false);
			void build_main_system_menuitems(menuitem_t *menu, bool is_root = false);


			void backup_native_items(HMENU hMenu, uint32_t id, bool check = false);

			WND *OnMenuCreate(HWND hWnd);
			void OnMenuShow(HWND hWnd, WND *wnd = nullptr);
			bool CreateLayer(WND *wnd);
			void UpdateLayered(WND *wnd, bool update_blurry = false);
			bool draw_layer(WND *wnd, SIZE size, int margin);
			void screenshot();

			HMENU MenuHandle() const;

			/*template<typename T = long>
			T dpi(auto value) const { return static_cast<T>(std::rint(value * double(_dpi) / 96.0)); }

			template<typename T = long>
			T original_dpi(auto value) const { return static_cast<T>(std::rint(value * double(_odpi) / 96.0)); }

			long xdpi(auto value) const
			{
				return static_cast<long>(std::rint(value * double(_dpi) / double(_odpi)));
			}
			*/
			void draw_string(HDC hdc, HFONT hFont, const Rect *rc, const Color &color, const wchar_t *text, int length = -1, DWORD format = 0, bool disable_BufferedPaint = false);

		public:
			// static variables
			inline static std::unordered_map<ContextMenu *, bool> Processes;
			inline static bool FontNotFound = false;
			inline static POINT point = {};
			inline static std::unordered_map<HWINEVENTHOOK, ContextMenu *> HookMap;

		public: 
			// static functions
			inline static void draw_rect(DC *dc, const POINT &pt, const SIZE &size, const Color &color, const Color &border = {}, int radius = 0);

			static void __stdcall Invoke(ContextMenu *cm);
			/*static LRESULT __stdcall TipProc(HWND hWnd, UINT uMsg, WPARAM wParam, LPARAM lParam,
											 UINT_PTR uIdSubclass, DWORD_PTR dwRefData);*/
			static LRESULT __stdcall WindowSubclassProc(HWND hWnd, UINT uMsg, WPARAM wParam, LPARAM lParam,
														UINT_PTR uIdSubclass, DWORD_PTR dwRefData);
			//static LRESULT __stdcall MenuProc(HWND hWnd, uint32_t uMsg, WPARAM wParam, LPARAM lParam);
			static LRESULT __stdcall MenuSubClassProc(HWND hWnd, UINT uMsg, WPARAM wParam, LPARAM lParam, UINT_PTR uIdSubclass, DWORD_PTR dwRefData);
			static void __stdcall WinEventProc(HWINEVENTHOOK hWinEventHook, DWORD dwEvent, HWND hWnd, LONG idObject, LONG idChild, DWORD idEventThread, DWORD dwmsEventTime);
			static LRESULT __stdcall KeyboardProc(int nCode, WPARAM wParam, LPARAM lParam);

			inline static bool UnRegisterLayer()
			{
				return ::UnregisterClassW(WC_Shell_Window, Path::GetCurrentModule());
				//return DLL::User32<ATOM>("UnregisterClassW", WC_Shell_Window, Path::GetCurrentModule());
			}

			inline static ATOM RegisterLayer()
			{
				WNDCLASSW wc_Layer{};
				wc_Layer.hInstance = Path::GetCurrentModule();
				wc_Layer.hbrBackground = static_cast<HBRUSH>(::GetStockObject(BLACK_BRUSH));
				//wc_Layer.hbrBackground = ::CreateSolidBrush(_theme.frame.background);// reinterpret_cast<HBRUSH>(NULL_BRUSH);
				wc_Layer.lpszClassName = WC_Shell_Window;
				wc_Layer.lpfnWndProc = LayerProc; /*::DefWindowProcW;*/
				return ::RegisterClassW(&wc_Layer);
			}

			inline static ContextMenu *CreateAndInitialize(HWND hWnd, HMENU hMenu, Point const &pt, bool explorer, bool contextmenuhandler)
			{
				if(!Initializer::Status.Disabled)
				{
					auto ctx = new ContextMenu(hWnd, hMenu, pt);
					ctx->Selected.loader.explorer = explorer;
					ctx->Selected.loader.contextmenuhandler = contextmenuhandler;
					// Lets QuerySelected match a selection the host already handed us
					// through IShellExtInit against the menu it is about to show.
					ctx->Selected.hmenu_original = hMenu;
					if(ctx->Initialize())
						return ctx;
					delete ctx;
				}
				return nullptr;
			}

			static bool is_swap_button()
			{
				/*
				auto fResult = GetSystemMetrics(SM_MOUSEPRESENT);
				if(fResult == 0)
					printf("No mouse installed.\n");
				else
				{
					printf("Mouse installed.\n");
					// Determine whether the buttons are swapped. 
					fResult = GetSystemMetrics(SM_SWAPBUTTON);
					if(fResult == 0)
						printf("Buttons not swapped.\n");
					else printf("Buttons swapped.\n");
				}
				*/
				return Theme::SystemMetrics(SM_SWAPBUTTON, 0, true);
			}
		};
	}
}