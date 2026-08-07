#pragma once
#include "Include/Theme.h"

namespace Nilesoft
{
	namespace Shell
	{
		struct D2D_DC
		{
			inline static ID2D1Factory *D2D1Factory = nullptr;
			inline static IDWriteFactory *DWriteFactory = nullptr;
			inline static ID2D1DCRenderTarget *render = nullptr;

			inline static IDWriteTextFormat *textFormat = nullptr;
			inline static ID2D1SolidColorBrush *brush = nullptr;

			~D2D_DC()
			{
				D2D1Factory = release(D2D1Factory);
				DWriteFactory = release(DWriteFactory);
				render = release(render);
				textFormat = release(textFormat);
				brush = release(brush);
			}

			static void reset_target()
			{
				if(render)
					render->Release();
				render = nullptr;
			}

			static bool init()
			{
				HRESULT hr = S_OK;

				if(!D2D1Factory)
				{
					hr = ::D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, {}, &D2D1Factory);
					if(hr != S_OK)
						return false;
				}

				if(!DWriteFactory)
				{
					hr = ::DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(DWriteFactory), reinterpret_cast<IUnknown **>(&DWriteFactory));
				}

				return hr == S_OK;
			}

			static bool init_res()
			{
				if(init() && create_render())
				{
					return create_res();
				}
				return false;
			}

			static bool create_render()
			{
				if(init() && !render)
				{
					D2D1Factory->CreateDCRenderTarget(&props, &render);
				}
				return render;
			}

			static IDWriteTextFormat *createTextFormat(LPCWSTR name, int size, DWRITE_FONT_WEIGHT weight = DWRITE_FONT_WEIGHT_NORMAL, 
													   DWRITE_FONT_STYLE style = DWRITE_FONT_STYLE_NORMAL)
			{
				IDWriteTextFormat *_textFormat = nullptr;
				if(DWriteFactory)
					DWriteFactory->CreateTextFormat(name, nullptr, weight, style, DWRITE_FONT_STRETCH_NORMAL, (float)size, L"", &_textFormat);
				return _textFormat;
			}

			static ID2D1SolidColorBrush *createSolidColorBrush(D2D1::ColorF color)
			{
				ID2D1SolidColorBrush *_brush = nullptr;
				if(render)
					render->CreateSolidColorBrush(color, &_brush);
				return _brush;
			}

			static bool create_res()
			{
				if(!brush)
				{
					brush = createSolidColorBrush(D2D1::ColorF::White);
				}
				//if(!textFormat)
				//	textFormat = createTextFormat(L"Segoe UI", 12);

				return brush;//&& textFormat;
			}

			static void delete_res()
			{
				brush = release(brush);
				textFormat = release(textFormat);
			}

			static HRESULT bind(HDC hDC, const Rect rect)
			{
				create_render();
				return render ? render->BindDC(hDC, rect) : S_FALSE;
			}

			static void begin()
			{
				if(create_render())
					render->BeginDraw();
			}

			static HRESULT end(bool reset = false)
			{
				HRESULT hr = S_FALSE;
				if(render)
				{
					hr = render->EndDraw();
					if(reset && hr == D2DERR_RECREATE_TARGET)
					{
						reset_target();
					}
				}
				return hr;
			}

			template<typename T>
			static T *release(T *obj)
			{
				if(obj) obj->Release();
				return nullptr;
			}

		private:
			inline static const D2D1_RENDER_TARGET_PROPERTIES props = D2D1::RenderTargetProperties(
				D2D1_RENDER_TARGET_TYPE_DEFAULT,
				D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED),
				0,
				0,
				D2D1_RENDER_TARGET_USAGE_NONE,
				D2D1_FEATURE_LEVEL_DEFAULT
			);
		};
		/*
		struct D2D_DC
		{
			inline static ID2D1Factory *D2D1Factory = nullptr;
			inline static IDWriteFactory *DWriteFactory = nullptr;

			ID2D1DCRenderTarget *render = nullptr;
			IDWriteTextFormat *textFormat = nullptr;
			ID2D1SolidColorBrush *brush = nullptr;

			HDC _hdc = nullptr;
			RECT _size;

			D2D_DC()
			{
			}

			D2D_DC(HDC hwnd, RECT rc)
				: _hdc{ hwnd }, _size({ w, h })
			{
			}

			~D2D_DC()
			{
				D2D1Factory = release(D2D1Factory);
				DWriteFactory = release(DWriteFactory);
				render = release(render);
				textFormat = release(textFormat);
				brush = release(brush);
			}

			bool create_render(HWND hwnd, uint32_t w, uint32_t h)
			{
				//_hwnd = hwnd;
				//_size = { w, h };
				return create_render();
			}

			bool create_render()
			{
					if(init() && !render)
				{
						D2D1Factory->CreateDCRenderTarget(&props, &render);
				}
				return render;
			}

			HRESULT bind(HDC hDC, RECT *pSubRect)
			{
				create_render();
				return render ? render->BindDC(hDC, pSubRect) : S_FALSE;
			}

			void begin()
			{
				if(create_render())
					render->BeginDraw();
			}

			HRESULT end(bool reset = false)
			{
				HRESULT hr = S_FALSE;
				if(render)
				{
					hr = render->EndDraw();
					if(reset && hr == D2DERR_RECREATE_TARGET)
					{
						reset_target();
					}
				}
				return hr;
			}

			void reset_target()
			{
				if(render)
					render->Release();
				render = nullptr;
			}

			static bool init()
			{
				HRESULT hr = S_OK;

				if(!D2D1Factory)
				{
					hr = ::D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, {}, &D2D1Factory);
					if(hr != S_OK)
						return false;
				}

				if(!DWriteFactory)
				{
					hr = ::DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(DWriteFactory), reinterpret_cast<IUnknown **>(&DWriteFactory));
				}

				return hr == S_OK;
			}

			bool init_res()
			{
				if(init() && create_render())
				{
					return create_res();
				}
				return false;
			}

			static IDWriteTextFormat *createTextFormat(LPCWSTR name, int size, DWRITE_FONT_WEIGHT weight = DWRITE_FONT_WEIGHT_NORMAL, DWRITE_FONT_STYLE style = DWRITE_FONT_STYLE_NORMAL)
			{
				IDWriteTextFormat *_textFormat = nullptr;
				if(DWriteFactory)
					DWriteFactory->CreateTextFormat(name, nullptr, weight, style, DWRITE_FONT_STRETCH_NORMAL, (float)size, L"", &_textFormat);
				return _textFormat;
			}

			ID2D1SolidColorBrush *createSolidColorBrush(D2D1::ColorF color)
			{
				ID2D1SolidColorBrush *_brush = nullptr;
				if(render)
					render->CreateSolidColorBrush(color, &_brush);
				return _brush;
			}

			bool create_res()
			{
				if(!brush)
				{
					brush = createSolidColorBrush(D2D1::ColorF::White);
				}
				//if(!textFormat)
				//	textFormat = createTextFormat(L"Segoe UI", 12);

				return brush;//&& textFormat;
			}

			void delete_res()
			{
				brush = release(brush);
				textFormat = release(textFormat);
			}

			template<typename T>
			static T *release(T *obj)
			{
				if(obj) obj->Release();
				return nullptr;
			}

		private:
			inline static const D2D1_RENDER_TARGET_PROPERTIES props = D2D1::RenderTargetProperties(
				D2D1_RENDER_TARGET_TYPE_DEFAULT,
				D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED),
				0,
				0,
				D2D1_RENDER_TARGET_USAGE_NONE,
				D2D1_FEATURE_LEVEL_DEFAULT
			);
		};
		*/
		// A Direct2D/DirectWrite wrapper used to live here, backing an alternative
		// menu renderer. That renderer was unreachable (its only entry point sat
		// behind a hardcoded false), so the wrapper was deleted with it. Removing
		// it also dropped d2d1.dll and dwrite.dll from the import table, which
		// OPT:REF had not been stripping.

		class Initializer
		{
		private:
			uintptr_t _last_write_time{};

		public:
			struct {
				HMODULE	hModule{};
				HANDLE	handle{};
				DWORD	id{};
				string	name;
				string	path;
			} process;

			Application		application;
			// No COM_INITIALIZER member. As a member of a global it initialised
			// COM on the thread that loaded the DLL and then, at teardown, ran
			// CoUninitialize from whichever thread destroys globals, which is
			// not the thread that had incremented the count. COM is now brought
			// up per-thread in Initializer::init.
			bool			is_elevated{};
			CACHE *cache{};
			//Hooker			user32_TrackPopupMenu;
			//Hooker			user32_TrackPopupMenuEx;
			//Hooker			user32u_TrackPopupMenuEx;
			uint32_t		dpi = 96;

			Initializer() { instance = this; };
			~Initializer();

			bool query(int ch = 0);
			bool init(HINSTANCE hInstance);
			bool init();
			static void ensure_com();
			// Clean up resources allocated during initialization.
			bool uninit();

			//reloadOnChange
			//determine
			bool config_has_changed();
			bool has_error(bool detect_changes = false);
			void load_mui();

			struct STATUS { bool Loaded, Disabled, Refresh, Error; } inline static Status{};

			struct LASTERROR 
			{ 
				TokenError code{};
				uint32_t line, col{};
			} inline static LastError{};

		public:
			inline static Initializer *instance{};
			inline static HINSTANCE HInstance{};

			static bool Inited()
			{
				return Status.Loaded;
			}

			//static HRESULT Modern(int enabled);
			static bool OnState(bool istaskbar = false);

			inline static std::unordered_map<uint32_t, MUID> MAP_MUID;

			static MUID* get_muid(uint32_t hash)
			{
				for(auto &it : MAP_MUID)
				{
					if(it.first == hash or it.second.hash == hash)
						return &it.second;
				}
				return nullptr;
			}

			static uint32_t get_hash(uint32_t id)
			{
				for(auto &it : MAP_MUID)
				{
					if(it.first == id)
						return it.second.hash;
				}
				return 0;
			}

			/*
			static bool IsLanguageRTL(void)
			{
				LOCALESIGNATURE localesig{};
				LANGID language = ::GetUserDefaultUILanguage();
				if(::GetLocaleInfoW(language, LOCALE_FONTSIGNATURE, 
								  (LPWSTR)&localesig,
								  (sizeof(localesig) / sizeof(wchar_t))) && (localesig.lsUsb[3] & 0x08000000))
					return true;
				return false;
			}*/
		};
	}
}