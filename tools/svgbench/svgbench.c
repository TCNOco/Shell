// Times plutosvg rasterisation over the icon set this project actually ships,
// and dumps the pixels it produced.
//
// The existing VM smoke test measures whole-menu latency, which is the right
// number for the menu build path but the wrong one for a rasteriser change:
// it needs a Hyper-V guest, and BitmapCache means each icon is rastered once
// and then reused, so the cost being changed here is mostly invisible to it.
//
// Two outputs, because a library upgrade can regress either one:
//   - timings, so "faster" is a measurement rather than a claim
//   - raw pixels, so "renders the same" is checkable rather than eyeballed
//
// Build both sides with tools/svgbench/Build-Bench.ps1, which compiles this
// once against the committed prebuilt lib and once against the new one. The
// only difference is SVGBENCH_NEW.
//
// The old API parses and renders in a single call, so only a combined number
// is available for it. The new API separates the two, and they are reported
// separately as well as combined -- a document parsed once can be rendered at
// several sizes, which the old API could not express.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <windows.h>
#include <psapi.h>

#include "plutosvg.h"

#ifdef SVGBENCH_NEW
    #define SURF_DATA(s)   plutovg_surface_get_data(s)
    #define SURF_WIDTH(s)  plutovg_surface_get_width(s)
    #define SURF_HEIGHT(s) plutovg_surface_get_height(s)
    #define SURF_STRIDE(s) plutovg_surface_get_stride(s)
    #define BUILD_LABEL    "new"
#else
    // The vendored plutovg.h de-opaques the surface struct, so these are reads
    // rather than calls. Upstream has kept it opaque since its first commit.
    #define SURF_DATA(s)   ((s)->data)
    #define SURF_WIDTH(s)  ((s)->width)
    #define SURF_HEIGHT(s) ((s)->height)
    #define SURF_STRIDE(s) ((s)->stride)
    #define BUILD_LABEL    "old"
#endif

#define MAX_FILES 512
#define MAX_SIZES 8

typedef struct {
    char  name[128];
    char *data;
    int   length;
} svg_file;

typedef struct {
    double parse_us;
    double render_us;
    double total_us;
    int    ok;
    int    width;
    int    height;
} sample;

static double qpc_freq;

static double now_us(void)
{
    LARGE_INTEGER c;
    QueryPerformanceCounter(&c);
    return (double)c.QuadPart * 1e6 / qpc_freq;
}

static int cmp_double(const void *a, const void *b)
{
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}

// Percentile over an already-sorted array, nearest-rank.
static double pct(const double *sorted, int n, double p)
{
    if(n <= 0) return 0.0;
    int i = (int)(p * (n - 1) + 0.5);
    if(i < 0) i = 0;
    if(i >= n) i = n - 1;
    return sorted[i];
}

static char *read_all(const char *path, int *out_len)
{
    FILE *f = NULL;
    if(fopen_s(&f, path, "rb") != 0 || !f) return NULL;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    if(n <= 0) { fclose(f); return NULL; }
    char *buf = (char *)malloc((size_t)n);
    if(!buf) { fclose(f); return NULL; }
    size_t got = fread(buf, 1, (size_t)n, f);
    fclose(f);
    if(got != (size_t)n) { free(buf); return NULL; }
    *out_len = (int)n;
    return buf;
}

static int load_corpus(const char *dir, svg_file *files, int max)
{
    char pattern[MAX_PATH];
    sprintf_s(pattern, sizeof(pattern), "%s\\*.svg", dir);

    WIN32_FIND_DATAA fd;
    HANDLE h = FindFirstFileA(pattern, &fd);
    if(h == INVALID_HANDLE_VALUE) return 0;

    int n = 0;
    do {
        if(n >= max) break;
        if(fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) continue;

        char path[MAX_PATH];
        sprintf_s(path, sizeof(path), "%s\\%s", dir, fd.cFileName);

        int len = 0;
        char *data = read_all(path, &len);
        if(!data) continue;

        strncpy_s(files[n].name, sizeof(files[n].name), fd.cFileName, _TRUNCATE);
        files[n].data = data;
        files[n].length = len;
        n++;
    } while(FindNextFileA(h, &fd));

    FindClose(h);
    return n;
}

#ifdef SVGBENCH_NEW
// Scales the document into a size x size surface, preserving aspect and
// centring, rather than letting plutosvg_document_render_to_surface decide.
//
// It has to be explicit, because an SVG carrying neither viewBox nor
// width/height reports the CSS default 300x150 and then renders 1:1 into
// whatever surface it is given -- so a 32px request shows the top-left 32x32
// units of the artwork instead of the artwork. The old library scaled the
// content to fit, and @code in src/bin/imports/images.nss is exactly that
// shape, so leaving it implicit is a visible regression.
//
// 300x150 as the sentinel is the SVG default for a document with no intrinsic
// size. A document genuinely authored at 300x150 with a viewBox would be
// fitted by its extents instead of its viewBox, which crops differently only
// if the artwork does not fill its own viewBox. No such icon ships here, and
// the alternative -- misplacing artwork that has no viewBox at all -- is worse.
static plutovg_surface_t *fit_render(plutosvg_document_t *doc, int size)
{
    float sx = 0.0f, sy = 0.0f;
    float sw = plutosvg_document_get_width(doc);
    float sh = plutosvg_document_get_height(doc);

    if(sw == 300.0f && sh == 150.0f)
    {
        plutovg_rect_t ext;
        if(plutosvg_document_extents(doc, NULL, &ext) && ext.w > 0.0f && ext.h > 0.0f)
        {
            sx = ext.x; sy = ext.y; sw = ext.w; sh = ext.h;
        }
    }

    if(sw <= 0.0f || sh <= 0.0f) return NULL;

    float scale = (float)size / sw;
    float sv    = (float)size / sh;
    if(sv < scale) scale = sv;

    plutovg_surface_t *surf = plutovg_surface_create(size, size);
    if(!surf) return NULL;

    plutovg_canvas_t *canvas = plutovg_canvas_create(surf);
    if(!canvas) { plutovg_surface_destroy(surf); return NULL; }

    plutovg_canvas_translate(canvas, ((float)size - sw * scale) * 0.5f,
                                     ((float)size - sh * scale) * 0.5f);
    plutovg_canvas_scale(canvas, scale, scale);
    plutovg_canvas_translate(canvas, -sx, -sy);

    plutosvg_document_render(doc, NULL, canvas, NULL, NULL, NULL);
    plutovg_canvas_destroy(canvas);
    return surf;
}
#endif

// One parse+render of a single icon at one size. Fills a sample and, when dump
// is non-NULL, writes the pixels it produced.
static void render_one(const svg_file *f, int size, sample *s, const char *dump)
{
    memset(s, 0, sizeof(*s));

#ifdef SVGBENCH_NEW
    // -1 for the container, not the target size. The container resolves
    // percentage lengths, so passing the target makes a document with no
    // width/height report the target as its intrinsic size, and the fit below
    // then becomes a no-op scale of 1. Asking for the document's own size and
    // scaling it explicitly is what reproduces the old library's framing.
    double t0 = now_us();
    plutosvg_document_t *doc =
        plutosvg_document_load_from_data(f->data, f->length, -1.0f, -1.0f, NULL, NULL);
    double t1 = now_us();
    if(!doc) { s->total_us = t1 - t0; s->parse_us = t1 - t0; return; }

    plutovg_surface_t *surf = fit_render(doc, size);
    double t2 = now_us();

    s->parse_us  = t1 - t0;
    s->render_us = t2 - t1;
    s->total_us  = t2 - t0;
#else
    double t0 = now_us();
    plutovg_surface_t *surf =
        plutosvg_load_from_memory(f->data, f->length, NULL, size, size, 96.0);
    double t1 = now_us();

    // The old API gives no way to separate the two.
    s->parse_us  = 0.0;
    s->render_us = 0.0;
    s->total_us  = t1 - t0;
#endif

    if(surf)
    {
        s->ok = 1;
        s->width  = SURF_WIDTH(surf);
        s->height = SURF_HEIGHT(surf);

        if(dump)
        {
            // Tightly packed so the two builds stay comparable even if they
            // choose different stride padding. 8-byte header, then rows.
            char out[MAX_PATH];
            sprintf_s(out, sizeof(out), "%s\\%s@%d.raw", dump, f->name, size);
            FILE *g = NULL;
            if(fopen_s(&g, out, "wb") == 0 && g)
            {
                int w = s->width, h = s->height, stride = SURF_STRIDE(surf);
                const unsigned char *px = SURF_DATA(surf);
                fwrite(&w, sizeof(w), 1, g);
                fwrite(&h, sizeof(h), 1, g);
                for(int y = 0; y < h; y++)
                    fwrite(px + (size_t)y * stride, 1, (size_t)w * 4, g);
                fclose(g);
            }
        }
        plutovg_surface_destroy(surf);
    }

#ifdef SVGBENCH_NEW
    plutosvg_document_destroy(doc);
#endif
}

static void usage(void)
{
    printf("usage: svgbench --corpus <dir> [--sizes 16,20,24,32] [--reps 25]\n"
           "                [--dump <dir>] [--json <file>]\n");
}

int main(int argc, char **argv)
{
    LARGE_INTEGER f;
    QueryPerformanceFrequency(&f);
    qpc_freq = (double)f.QuadPart;

    const char *corpus = NULL, *dump = NULL, *json = NULL;
    int sizes[MAX_SIZES] = { 16, 20, 24, 32 };
    int nsizes = 4;
    int reps = 25;

    for(int i = 1; i < argc; i++)
    {
        if(!strcmp(argv[i], "--corpus") && i + 1 < argc)     corpus = argv[++i];
        else if(!strcmp(argv[i], "--dump") && i + 1 < argc)  dump = argv[++i];
        else if(!strcmp(argv[i], "--json") && i + 1 < argc)  json = argv[++i];
        else if(!strcmp(argv[i], "--reps") && i + 1 < argc)  reps = atoi(argv[++i]);
        else if(!strcmp(argv[i], "--sizes") && i + 1 < argc)
        {
            nsizes = 0;
            char *tok = NULL, *ctx = NULL;
            char buf[128];
            strncpy_s(buf, sizeof(buf), argv[++i], _TRUNCATE);
            tok = strtok_s(buf, ",", &ctx);
            while(tok && nsizes < MAX_SIZES) { sizes[nsizes++] = atoi(tok); tok = strtok_s(NULL, ",", &ctx); }
        }
        else { usage(); return 2; }
    }

    if(!corpus || reps < 1) { usage(); return 2; }

    static svg_file files[MAX_FILES];
    int nfiles = load_corpus(corpus, files, MAX_FILES);
    if(nfiles == 0) { printf("svgbench: no .svg files in %s\n", corpus); return 1; }

    if(dump) CreateDirectoryA(dump, NULL);

    printf("svgbench [%s] %d icons, sizes", BUILD_LABEL, nfiles);
    for(int i = 0; i < nsizes; i++) printf(" %d", sizes[i]);
    printf(", %d reps\n\n", reps);

    FILE *jf = NULL;
    if(json && fopen_s(&jf, json, "wb") == 0 && jf)
        fprintf(jf, "{\n  \"build\": \"%s\",\n  \"icons\": %d,\n  \"reps\": %d,\n  \"sizes\": [\n", BUILD_LABEL, nfiles, reps);

    double *per_icon = (double *)malloc(sizeof(double) * nfiles);
    double *samples  = (double *)malloc(sizeof(double) * reps);
    int total_failures = 0;

    for(int si = 0; si < nsizes; si++)
    {
        int size = sizes[si];
        int failures = 0;
        double corpus_total = 0.0, parse_total = 0.0, render_total = 0.0;

        for(int fi = 0; fi < nfiles; fi++)
        {
            double parse_min = 1e30, render_min = 1e30;

            for(int r = 0; r < reps; r++)
            {
                sample s;
                // Pixels are dumped once per icon, on the first rep, so the
                // file I/O stays out of every other timing.
                render_one(&files[fi], size, &s, (r == 0) ? dump : NULL);
                samples[r] = s.total_us;
                if(s.parse_us  < parse_min)  parse_min  = s.parse_us;
                if(s.render_us < render_min) render_min = s.render_us;
                if(r == 0 && !s.ok) failures++;
            }

            qsort(samples, reps, sizeof(double), cmp_double);
            // Minimum rather than mean: this is a deterministic CPU-bound
            // workload, so the fastest run is the one least polluted by
            // scheduling and cache noise.
            per_icon[fi]  = samples[0];
            corpus_total += samples[0];
            parse_total  += parse_min;
            render_total += render_min;
        }

        qsort(per_icon, nfiles, sizeof(double), cmp_double);
        double med = pct(per_icon, nfiles, 0.50);
        double p95 = pct(per_icon, nfiles, 0.95);

        printf("  %2dpx  corpus %8.1f us   per-icon median %6.1f us  p95 %6.1f us  max %6.1f us",
               size, corpus_total, med, p95, per_icon[nfiles - 1]);
        if(failures) printf("   FAILED %d", failures);
        printf("\n");
#ifdef SVGBENCH_NEW
        printf("        parse %8.1f us   render %8.1f us\n", parse_total, render_total);
#endif

        total_failures += failures;

        if(jf)
        {
            fprintf(jf,
                "    {\"size\": %d, \"corpusTotalUs\": %.1f, \"medianUs\": %.1f, \"p95Us\": %.1f, "
                "\"maxUs\": %.1f, \"parseTotalUs\": %.1f, \"renderTotalUs\": %.1f, \"failures\": %d}%s\n",
                size, corpus_total, med, p95, per_icon[nfiles - 1],
                parse_total, render_total, failures, (si + 1 < nsizes) ? "," : "");
        }
    }

    PROCESS_MEMORY_COUNTERS pmc;
    double peak_mb = 0.0;
    if(GetProcessMemoryInfo(GetCurrentProcess(), &pmc, sizeof(pmc)))
        peak_mb = (double)pmc.PeakWorkingSetSize / (1024.0 * 1024.0);
    printf("\n  peak working set %.1f MB\n", peak_mb);

    if(jf)
    {
        fprintf(jf, "  ],\n  \"peakWorkingSetMb\": %.1f,\n  \"totalFailures\": %d\n}\n", peak_mb, total_failures);
        fclose(jf);
    }

    if(total_failures)
    {
        printf("\n  %d render failures\n", total_failures);
        return 1;
    }
    return 0;
}
