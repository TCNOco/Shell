// Covers the drawing path through PlutoVGWrap.
//
// The port from the 2022 plutovg to v1.3.3 rewrote every member of this
// wrapper: the drawing context became a canvas, the surface became opaque, and
// gradients stopped accepting stops one at a time. None of that fails to
// compile if it is wrong -- it fails by drawing the wrong pixels on the menu
// paint path, where nothing else here would notice.
//
// tools/svgbench covers rasterisation throughput and whole-corpus fidelity
// against the previous library. This covers the parts svgbench cannot reach:
// the shapes, fills, strokes, clears and gradients that draw the menu itself.

#include <windows.h>

#include "test.h"

#include <System/Drawing/Color.h>
#include <Library/PlutoVGWrap.h>

using namespace Nilesoft::Shell;

namespace
{
	// Premultiplied BGRA, as plutovg produces and tobitmap consumes.
	struct Pixel { uint8_t b, g, r, a; };

	Pixel pixel_at(const PlutoVG &p, int x, int y)
	{
		const uint8_t *row = p.data() + (size_t)y * p.stride();
		const uint8_t *px = row + (size_t)x * 4;
		return { px[0], px[1], px[2], px[3] };
	}

	int opaque_pixels(const PlutoVG &p)
	{
		int n = 0;
		for(int y = 0; y < p.height(); y++)
			for(int x = 0; x < p.width(); x++)
				if(pixel_at(p, x, y).a != 0) n++;
		return n;
	}

	// A 16x16 viewBox filling itself with one flat colour. Enough to tell
	// "rendered at the right scale" from "rendered at the wrong one".
	const char *const kSquare =
		"<svg viewBox=\"0 0 16 16\"><rect x=\"0\" y=\"0\" width=\"16\" height=\"16\" fill=\"#ff0000\"/></svg>";

	// No viewBox, no width/height, and artwork that does not start at the
	// origin -- the shape that regressed when the new library was dropped in.
	// @code in src/bin/imports/images.nss is this shape.
	const char *const kNoViewBox =
		"<svg><rect x=\"40\" y=\"20\" width=\"40\" height=\"20\" fill=\"#00ff00\"/></svg>";
}

TEST(plutovgwrap, blank_surface_has_the_requested_size_and_is_transparent)
{
	PlutoVG p(24, 24);
	CHECK(static_cast<bool>(p));
	CHECK_EQ(p.width(), 24);
	CHECK_EQ(p.height(), 24);
	CHECK(p.stride() >= 24 * 4);
	CHECK_EQ(opaque_pixels(p), 0);
}

TEST(plutovgwrap, a_filled_rect_covers_what_it_should_and_nothing_else)
{
	PlutoVG p(20, 20);
	p.rect(5, 5, 10, 10).fill(0xFF0000, 255);

	auto inside = pixel_at(p, 10, 10);
	CHECK_EQ((int)inside.a, 255);
	CHECK_EQ((int)inside.r, 255);
	CHECK_EQ((int)inside.g, 0);
	CHECK_EQ((int)inside.b, 0);

	// Outside the rect must be untouched, which is what catches a rect whose
	// arguments were reinterpreted as x2/y2 rather than width/height.
	CHECK_EQ((int)pixel_at(p, 1, 1).a, 0);
	CHECK_EQ((int)pixel_at(p, 18, 18).a, 0);
	CHECK_EQ(opaque_pixels(p), 100);
}

TEST(plutovgwrap, alpha_is_premultiplied)
{
	PlutoVG p(8, 8);
	p.rect(0, 0, 8, 8).fill(0xFFFFFF, 128);

	// Half-transparent white stores as roughly half-intensity, not full.
	auto px = pixel_at(p, 4, 4);
	CHECK(px.a > 120 && px.a < 136);
	CHECK(px.r < 200);
	CHECK_EQ((int)px.r, (int)px.b);
}

TEST(plutovgwrap, clear_punches_a_hole_and_leaves_the_rest)
{
	PlutoVG p(20, 20);
	p.rect(0, 0, 20, 20).fill(0x0000FF, 255);
	CHECK_EQ(opaque_pixels(p), 400);

	p.rect(5, 5, 10, 10).clear();

	CHECK_EQ((int)pixel_at(p, 10, 10).a, 0);
	CHECK_EQ((int)pixel_at(p, 1, 1).a, 255);
	CHECK_EQ(opaque_pixels(p), 300);
}

TEST(plutovgwrap, clear_restores_the_operator_for_later_drawing)
{
	PlutoVG p(20, 20);
	p.rect(0, 0, 20, 20).fill(0x0000FF, 255);
	p.rect(0, 0, 10, 10).clear();

	// If clear left the canvas on DST_OUT, this would erase instead of paint.
	p.rect(12, 12, 6, 6).fill(0x00FF00, 255);
	CHECK_EQ((int)pixel_at(p, 14, 14).a, 255);
	CHECK_EQ((int)pixel_at(p, 14, 14).g, 255);
}

TEST(plutovgwrap, stroke_draws_on_the_edge_not_the_middle)
{
	PlutoVG p(20, 20);
	p.rect(5, 5, 10, 10);
	p.stroke_width(2).stroke_fill(0xFFFFFF, 255);

	CHECK_EQ((int)pixel_at(p, 10, 10).a, 0);
	CHECK((int)pixel_at(p, 10, 5).a > 0);
}

TEST(plutovgwrap, save_and_restore_bracket_state)
{
	PlutoVG p(20, 20);
	p.save();
	p.rect(0, 0, 20, 20).fill(0xFF0000, 255);
	p.restore();
	p.rect(0, 0, 5, 5).fill(0x00FF00, 255);

	CHECK_EQ((int)pixel_at(p, 2, 2).g, 255);
	CHECK_EQ((int)pixel_at(p, 15, 15).r, 255);
}

// Gradients changed shape most of all: stops used to be added to a live
// object, and are now handed over as an array when the paint is built.
TEST(plutovgwrap, a_linear_gradient_runs_between_its_stops)
{
	PlutoVG p(32, 8);
	Gradient g;
	g.create_linear(0, 0, 32, 0);
	g.add_stop(0.0, 0xFF0000, 255);
	g.add_stop(1.0, 0x0000FF, 255);
	CHECK(static_cast<bool>(g));

	p.rect(0, 0, 32, 8).fill(g);

	auto left = pixel_at(p, 1, 4);
	auto right = pixel_at(p, 30, 4);
	CHECK(left.r > 200);
	CHECK(left.b < 60);
	CHECK(right.b > 200);
	CHECK(right.r < 60);
}

TEST(plutovgwrap, a_gradient_with_no_stops_is_not_usable)
{
	Gradient g;
	g.create_linear(0, 0, 10, 0);
	CHECK(!static_cast<bool>(g));
	CHECK(g.paint() == nullptr);
}

TEST(plutovgwrap, adding_a_stop_after_first_use_is_reflected)
{
	Gradient g;
	g.create_linear(0, 0, 16, 0);
	g.add_stop(0.0, 0xFF0000, 255);
	auto *first = g.paint();
	CHECK(first != nullptr);

	g.add_stop(1.0, 0x0000FF, 255);
	auto *second = g.paint();
	CHECK(second != nullptr);
	// The cached paint has to be discarded, or the second stop is silently lost.
	CHECK(second != first);
}

TEST(plutovgwrap, svg_with_a_viewbox_scales_to_the_requested_size)
{
	PlutoVG p(kSquare, (int)strlen(kSquare), 32, 32);
	CHECK(static_cast<bool>(p));
	CHECK_EQ(p.width(), 32);
	CHECK_EQ(p.height(), 32);

	// A 16x16 viewBox filled edge to edge must cover all 32x32 once scaled.
	CHECK_EQ(opaque_pixels(p), 32 * 32);
	CHECK_EQ((int)pixel_at(p, 16, 16).r, 255);
}

// The regression that dropping in the new library caused: with no viewBox the
// document reports the CSS default 300x150 and renders 1:1, so the artwork
// lands outside a small surface entirely and the icon comes out blank or
// clipped to a corner.
TEST(plutovgwrap, svg_without_a_viewbox_is_fitted_rather_than_cropped)
{
	PlutoVG p(kNoViewBox, (int)strlen(kNoViewBox), 32, 32);
	CHECK(static_cast<bool>(p));
	CHECK_EQ(p.width(), 32);
	CHECK_EQ(p.height(), 32);

	const int painted = opaque_pixels(p);
	CHECK(painted > 0);

	// Artwork is 40x20 at (40,20); fitted into 32x32 it should occupy a wide
	// band across the middle, not a corner and not the whole surface.
	CHECK(painted > 32 * 8);
	CHECK(painted < 32 * 32);
	CHECK((int)pixel_at(p, 16, 16).g == 255);
	CHECK_EQ((int)pixel_at(p, 16, 1).a, 0);
}

TEST(plutovgwrap, a_malformed_document_fails_without_a_surface)
{
	const char *junk = "not an svg at all";
	PlutoVG p(junk, (int)strlen(junk), 16, 16);
	CHECK(!static_cast<bool>(p));
	CHECK(p.data() == nullptr);
	CHECK_EQ(p.width(), 0);
}

TEST(plutovgwrap, tobitmap_produces_a_dib_of_the_same_size)
{
	PlutoVG p(12, 9);
	p.rect(0, 0, 12, 9).fill(0x123456, 255);

	uint8_t *bits = nullptr;
	HBITMAP bmp = p.tobitmap(&bits);
	CHECK(bmp != nullptr);
	CHECK(bits != nullptr);

	BITMAP info{};
	CHECK(::GetObjectW(bmp, sizeof(info), &info) != 0);
	CHECK_EQ((int)info.bmWidth, 12);
	CHECK_EQ((int)info.bmHeight, 9);

	// plutovg pads rows; the DIB does not. A flat copy that ignored the stride
	// would shear the image, so check the last row actually arrived.
	auto last = reinterpret_cast<const uint32_t *>(bits)[(size_t)8 * 12 + 11];
	CHECK_EQ((int)(last >> 24), 255);

	::DeleteObject(bmp);
}

TEST(plutovgwrap, tobitmap_on_an_empty_wrapper_returns_nothing)
{
	PlutoVG p;
	CHECK(p.tobitmap() == nullptr);
}

TEST(plutovgwrap, destroy_is_idempotent_and_leaves_the_wrapper_empty)
{
	PlutoVG p(8, 8);
	p.rect(0, 0, 8, 8).fill(0xFFFFFF, 255);
	p.destroy();
	p.destroy();
	CHECK(!static_cast<bool>(p));
	CHECK(p.data() == nullptr);
}

TEST(plutovgwrap, get_pixel_rejects_coordinates_outside_the_surface)
{
	PlutoVG p(8, 8);
	// Not white: get_pixel signals failure with CLR_INVALID, which is
	// 0xFFFFFFFF, and that is also what an opaque white pixel reads back as.
	// The sentinel cannot distinguish the two, so a caller must bounds-check
	// rather than test the return value.
	p.rect(0, 0, 8, 8).fill(0x123456, 255);
	CHECK(p.get_pixel(-1, 0) == CLR_INVALID);
	CHECK(p.get_pixel(0, 8) == CLR_INVALID);
	CHECK(p.get_pixel(8, 0) == CLR_INVALID);
	CHECK(p.get_pixel(4, 4) != CLR_INVALID);
}
