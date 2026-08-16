#pragma once

// Thin C++ layer over plutovg/plutosvg.
//
// Ported from the 2022-era plutovg to v1.3.3, which replaced the plutovg_t
// drawing context with plutovg_canvas_t and made plutovg_surface_t opaque.
// The public shape here is unchanged so the call sites in ContextMenu.cpp,
// Expression/Context.cpp and exe/Main.cpp did not have to move; everything
// that changed is behind these members.
//
// Two differences worth knowing about:
//
//  - Gradients are no longer built by adding stops to a live object. The new
//    API takes the whole stop array at creation, so Gradient accumulates stops
//    and builds the paint on first use.
//
//  - The dpi argument is accepted and ignored. The old plutosvg used it to
//    resolve physical units (mm, pt, in); the new one resolves units itself.
//    Icons here are unitless viewBox coordinates, so nothing shipped changes,
//    but an SVG sized in millimetres would now scale differently.

#include <plutosvg.h>

#include <vector>

namespace Nilesoft
{
	namespace Shell
	{
		struct Gradient
		{
			Gradient() = default;
			Gradient(double x1, double y1, double x2, double y2) { create_linear(x1, y1, x2, y2); }
			Gradient(double cx, double cy, double cr, double fx, double fy, double fr)
			{
				create_radial(cx, cy, cr, fx, fy, fr);
			}
			~Gradient() { reset(); }

			Gradient(const Gradient &) = delete;
			Gradient &operator=(const Gradient &) = delete;

			Gradient &create_linear(double x1, double y1, double x2, double y2)
			{
				reset();
				_kind = Kind::linear;
				_p[0] = (float)x1; _p[1] = (float)y1;
				_p[2] = (float)x2; _p[3] = (float)y2;
				return *this;
			}

			Gradient &create_radial(double cx, double cy, double cr, double fx, double fy, double fr)
			{
				reset();
				_kind = Kind::radial;
				_p[0] = (float)cx; _p[1] = (float)cy; _p[2] = (float)cr;
				_p[3] = (float)fx; _p[4] = (float)fy; _p[5] = (float)fr;
				return *this;
			}

			Gradient &add_stop(double offset, uint8_t r, uint8_t g, uint8_t b, uint8_t a = 255)
			{
				discard_paint();
				_stops.push_back({ (float)offset,
								   { r / 255.0f, g / 255.0f, b / 255.0f, a / 255.0f } });
				return *this;
			}

			Gradient &add_stop(double offset, uint32_t rgb, uint8_t a = 255)
			{
				return add_stop(offset, uint8_t((rgb >> 16) & 0xff), uint8_t((rgb >> 8) & 0xff),
								uint8_t(rgb & 0xff), a);
			}

			// Built on first use rather than at create_*, because the stops are
			// not known until later and the new API wants them all at once.
			plutovg_paint_t *paint()
			{
				if(_paint || _kind == Kind::none || _stops.empty())
					return _paint;

				const int n = (int)_stops.size();
				if(_kind == Kind::linear)
					_paint = plutovg_paint_create_linear_gradient(_p[0], _p[1], _p[2], _p[3],
																  PLUTOVG_SPREAD_METHOD_PAD,
																  _stops.data(), n, nullptr);
				else
					_paint = plutovg_paint_create_radial_gradient(_p[0], _p[1], _p[2], _p[3], _p[4], _p[5],
																  PLUTOVG_SPREAD_METHOD_PAD,
																  _stops.data(), n, nullptr);
				return _paint;
			}

			explicit operator bool() const { return _kind != Kind::none && !_stops.empty(); }

		private:
			enum class Kind { none, linear, radial };

			void discard_paint()
			{
				if(_paint) { plutovg_paint_destroy(_paint); _paint = nullptr; }
			}

			void reset()
			{
				discard_paint();
				_stops.clear();
				_kind = Kind::none;
			}

			Kind _kind{ Kind::none };
			float _p[6]{};
			std::vector<plutovg_gradient_stop_t> _stops;
			plutovg_paint_t *_paint{};
		};

		struct PlutoVG
		{
			plutovg_surface_t *surface{};
			plutovg_canvas_t *ctx{};

			PlutoVG() = default;

			PlutoVG(int width, int height) { create(width, height); }

			PlutoVG(const char *data, int size, int width, int height, double dpi = 96.0)
			{
				load_from_memory(data, size, width, height, dpi);
			}

			~PlutoVG() { destroy(); }

			PlutoVG(const PlutoVG &) = delete;
			PlutoVG &operator=(const PlutoVG &) = delete;

			explicit operator bool() const { return surface != nullptr; }

			uint8_t *data() const { return surface ? plutovg_surface_get_data(surface) : nullptr; }
			int stride() const { return surface ? plutovg_surface_get_stride(surface) : 0; }
			int width() const { return surface ? plutovg_surface_get_width(surface) : 0; }
			int height() const { return surface ? plutovg_surface_get_height(surface) : 0; }

			PlutoVG &destroy()
			{
				if(ctx) plutovg_canvas_destroy(ctx);
				if(surface) plutovg_surface_destroy(surface);
				ctx = nullptr;
				surface = nullptr;
				return *this;
			}

			PlutoVG &create(int width, int height)
			{
				destroy();
				surface = plutovg_surface_create(width, height);
				if(surface)
					ctx = plutovg_canvas_create(surface);
				return *this;
			}

			PlutoVG &load_from_memory(const char *data, int size, int width, int height, double dpi = 96.0)
			{
				(void)dpi;
				destroy();
				if(plutosvg_document_t *doc =
					   plutosvg_document_load_from_data(data, size, -1.0f, -1.0f, nullptr, nullptr))
				{
					surface = fit(doc, width, height);
					plutosvg_document_destroy(doc);
				}
				return *this;
			}

			PlutoVG &load_from_file(const char *filename, int width = 0, int height = 0, double dpi = 96.0)
			{
				(void)dpi;
				destroy();
				if(plutosvg_document_t *doc = plutosvg_document_load_from_file(filename, -1.0f, -1.0f))
				{
					surface = fit(doc, width, height);
					plutosvg_document_destroy(doc);
				}
				return *this;
			}

			PlutoVG &rect(double x, double y, double w, double h, double r = 0.0)
			{
				if(r == 0.0)
					plutovg_canvas_rect(ctx, (float)x, (float)y, (float)w, (float)h);
				else
					plutovg_canvas_round_rect(ctx, (float)x, (float)y, (float)w, (float)h, (float)r, (float)r);
				return *this;
			}

			PlutoVG &rect(double x, double y, double w, double h, double rx, double ry)
			{
				plutovg_canvas_round_rect(ctx, (float)x, (float)y, (float)w, (float)h, (float)rx, (float)ry);
				return *this;
			}

			PlutoVG &fill(bool preserve = false)
			{
				if(preserve) plutovg_canvas_fill_preserve(ctx);
				else plutovg_canvas_fill(ctx);
				return *this;
			}

			PlutoVG &fill(uint32_t rgb, uint8_t a = 255, bool preserve = false)
			{
				return source_color(rgb, a).fill(preserve);
			}

			PlutoVG &fill(uint8_t r, uint8_t g, uint8_t b, uint8_t a = 255, bool preserve = false)
			{
				return source_color(r, g, b, a).fill(preserve);
			}

			PlutoVG &fill(Gradient &gradient, bool preserve = false)
			{
				if(plutovg_paint_t *p = gradient.paint())
					plutovg_canvas_set_paint(ctx, p);
				return fill(preserve);
			}

			PlutoVG &stroke(bool preserve = false)
			{
				if(preserve) plutovg_canvas_stroke_preserve(ctx);
				else plutovg_canvas_stroke(ctx);
				return *this;
			}

			PlutoVG &stroke_width(double width) { return line_width(width); }

			PlutoVG &stroke_fill(uint32_t rgb, uint8_t a = 255, bool preserve = false)
			{
				return source_color(rgb, a).stroke(preserve);
			}

			PlutoVG &stroke_fill(uint8_t r, uint8_t g, uint8_t b, uint8_t a = 255, bool preserve = false)
			{
				return source_color(r, g, b, a).stroke(preserve);
			}

			// Punches the current path out of what has already been drawn. The
			// operator is put back afterwards because callers keep drawing
			// through the same canvas.
			PlutoVG &clear(bool preserve = false)
			{
				plutovg_canvas_set_operator(ctx, PLUTOVG_OPERATOR_DST_OUT);
				source_color(0xffffffff).fill(preserve);
				plutovg_canvas_set_operator(ctx, PLUTOVG_OPERATOR_SRC_OVER);
				return *this;
			}

			PlutoVG &source_color(uint32_t rgba)
			{
				return source_color(get_color(rgba, 16), get_color(rgba, 8),
									get_color(rgba, 0), get_color(rgba, 24));
			}

			PlutoVG &source_color(uint32_t rgb, uint8_t a)
			{
				return source_color(get_color(rgb, 16), get_color(rgb, 8), get_color(rgb, 0), a);
			}

			PlutoVG &source_color(uint8_t r, uint8_t g, uint8_t b, uint8_t a = 255)
			{
				plutovg_canvas_set_rgba(ctx, r / 255.0f, g / 255.0f, b / 255.0f, a / 255.0f);
				return *this;
			}

			PlutoVG &set_operator(plutovg_operator_t op) { plutovg_canvas_set_operator(ctx, op); return *this; }
			PlutoVG &set_fill_rule(plutovg_fill_rule_t winding) { plutovg_canvas_set_fill_rule(ctx, winding); return *this; }
			PlutoVG &clip(bool preserve = false)
			{
				if(preserve) plutovg_canvas_clip_preserve(ctx);
				else plutovg_canvas_clip(ctx);
				return *this;
			}
			PlutoVG &paint() { plutovg_canvas_paint(ctx); return *this; }
			PlutoVG &save() { plutovg_canvas_save(ctx); return *this; }
			PlutoVG &restore() { plutovg_canvas_restore(ctx); return *this; }
			PlutoVG &new_path() { plutovg_canvas_new_path(ctx); return *this; }
			PlutoVG &line_width(double width) { plutovg_canvas_set_line_width(ctx, (float)width); return *this; }

			uint32_t get_pixel(int x, int y) const
			{
				const int w = width(), h = height();
				if(!surface || x < 0 || y < 0 || x >= w || y >= h)
					return CLR_INVALID;
				return *reinterpret_cast<const uint32_t *>(data() + (size_t)y * stride() + (size_t)x * 4);
			}

			PlutoVG &set_pixel(int x, int y, uint32_t clr)
			{
				const int w = width(), h = height();
				if(!surface || x < 0 || y < 0 || x >= w || y >= h)
					return *this;
				*reinterpret_cast<uint32_t *>(data() + (size_t)y * stride() + (size_t)x * 4) = clr;
				return *this;
			}

			HBITMAP tobitmap(uint8_t **lpbits = nullptr) const
			{
				HBITMAP bitmap{};
				uint32_t *dst_bits = nullptr;
				const uint8_t *src = data();
				if(src)
				{
					const int w = width(), h = height(), sp = stride();
					BITMAPINFOHEADER bi = { sizeof(bi), w, -h, 1, 32 };
					bitmap = ::CreateDIBSection(nullptr, reinterpret_cast<BITMAPINFO *>(&bi), DIB_RGB_COLORS,
												reinterpret_cast<void **>(&dst_bits), nullptr, 0);
					if(bitmap)
					{
						// Row by row via the stride. The old surface was
						// tightly packed and copied as one run; plutovg pads
						// rows now, so a flat copy would shear the image.
						for(int y = 0; y < h; y++)
							memcpy(dst_bits + (size_t)y * w, src + (size_t)y * sp, (size_t)w * 4);

						if(lpbits)
							*lpbits = reinterpret_cast<uint8_t *>(dst_bits);
					}
				}

				return bitmap;
			}

			HBITMAP tobitmap(Nilesoft::Drawing::Color const &color) const
			{
				HBITMAP bitmap{};
				uint32_t *dst_bits{};
				const uint8_t *src = data();
				if(src)
				{
					const int w = width(), h = height(), sp = stride();
					BITMAPINFOHEADER bi = { sizeof(bi), w, -h, 1, 32 };
					bitmap = ::CreateDIBSection(nullptr, reinterpret_cast<BITMAPINFO *>(&bi), DIB_RGB_COLORS,
												reinterpret_cast<void **>(&dst_bits), nullptr, 0);
					if(bitmap)
					{
						for(int y = 0; y < h; y++)
						{
							auto row = reinterpret_cast<const uint32_t *>(src + (size_t)y * sp);
							auto out = dst_bits + (size_t)y * w;
							for(int x = 0; x < w; x++)
							{
								auto a = row[x] >> 24;
								if(a == 0) continue;
								auto r = (color.r() * a) / 255;
								auto g = (color.g() * a) / 255;
								auto b = (color.b() * a) / 255;
								out[x] = (a << 24) | (b << 16) | (g << 8) | r;
							}
						}
					}
				}

				return bitmap;
			}

			PlutoVG &rgba()
			{
				const int w = width(), h = height(), sp = stride();
				uint8_t *base = data();
				if(!base) return *this;
				for(int y = 0; y < h; y++)
				{
					auto pixels = reinterpret_cast<uint32_t *>(base + (size_t)sp * y);
					for(int x = 0; x < w; x++)
					{
						auto pixel = pixels[x];
						auto a = (pixel >> 24) & 0xFF;
						if(a == 0)
							continue;

						auto r = (pixel >> 16) & 0xFF;
						auto g = (pixel >> 8) & 0xFF;
						auto b = (pixel >> 0) & 0xFF;
						if(a != 255)
						{
							r = (r * 255) / a;
							g = (g * 255) / a;
							b = (b * 255) / a;
						}

						pixels[x] = (a << 24) | (b << 16) | (g << 8) | r;
					}
				}
				return *this;
			}

			static uint8_t get_color(uint32_t rgba, int8_t index) { return uint8_t((rgba >> index) & 0xff); }
			static uint8_t get_color_r(uint32_t rgba) { return uint8_t((rgba >> 16) & 0xff); }
			static uint8_t get_color_g(uint32_t rgba) { return uint8_t((rgba >> 8) & 0xff); }
			static uint8_t get_color_b(uint32_t rgba) { return uint8_t(rgba & 0xff); }
			static uint8_t get_color_a(uint32_t rgba) { return uint8_t((rgba >> 24) & 0xff); }

		private:
			// Scales the document into width x height, preserving aspect and
			// centring, instead of letting plutosvg choose.
			//
			// It has to be explicit. An SVG carrying neither viewBox nor
			// width/height reports the CSS default 300x150 and then renders 1:1
			// into whatever surface it is handed, so asking for 16px would show
			// the top-left 16x16 units of the artwork rather than the artwork.
			// The old library scaled content to fit, and @code in
			// src/bin/imports/images.nss is exactly that shape, so leaving it
			// implicit renders that icon cropped.
			//
			// 300x150 is the SVG default for a document with no intrinsic size.
			// One authored at exactly 300x150 *with* a viewBox would be fitted
			// by its extents instead, which differs only when the artwork does
			// not fill its own viewBox -- a better failure than misplacing
			// artwork that has no viewBox at all.
			static plutovg_surface_t *fit(plutosvg_document_t *doc, int width, int height)
			{
				float sx = 0.0f, sy = 0.0f;
				float sw = plutosvg_document_get_width(doc);
				float sh = plutosvg_document_get_height(doc);

				if(sw == 300.0f && sh == 150.0f)
				{
					plutovg_rect_t ext;
					if(plutosvg_document_extents(doc, nullptr, &ext) && ext.w > 0.0f && ext.h > 0.0f)
					{
						sx = ext.x; sy = ext.y; sw = ext.w; sh = ext.h;
					}
				}

				if(sw <= 0.0f || sh <= 0.0f) return nullptr;

				if(width <= 0) width = (int)(sw + 0.5f);
				if(height <= 0) height = (int)(sh + 0.5f);

				float scale = (float)width / sw;
				if(float sv = (float)height / sh; sv < scale) scale = sv;

				plutovg_surface_t *surf = plutovg_surface_create(width, height);
				if(!surf) return nullptr;

				plutovg_canvas_t *canvas = plutovg_canvas_create(surf);
				if(!canvas) { plutovg_surface_destroy(surf); return nullptr; }

				plutovg_canvas_translate(canvas, ((float)width - sw * scale) * 0.5f,
												 ((float)height - sh * scale) * 0.5f);
				plutovg_canvas_scale(canvas, scale, scale);
				plutovg_canvas_translate(canvas, -sx, -sy);

				plutosvg_document_render(doc, nullptr, canvas, nullptr, nullptr, nullptr);
				plutovg_canvas_destroy(canvas);
				return surf;
			}
		};
	}
}
