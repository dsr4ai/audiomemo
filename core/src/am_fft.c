#include "am_fft.h"
#include <math.h>
#include <stdlib.h>

int am_fft_init(am_fft *f, int n) {
    int lg = 0;
    while ((1 << lg) < n) lg++;
    if ((1 << lg) != n) return -1;
    f->n = n; f->log2n = lg;
    f->cos_t = (float *)malloc(sizeof(float) * (size_t)(n / 2));
    f->sin_t = (float *)malloc(sizeof(float) * (size_t)(n / 2));
    f->rev = (int *)malloc(sizeof(int) * (size_t)n);
    if (!f->cos_t || !f->sin_t || !f->rev) { am_fft_free(f); return -1; }
    for (int i = 0; i < n / 2; i++) {
        double a = -2.0 * M_PI * i / n;
        f->cos_t[i] = (float)cos(a); f->sin_t[i] = (float)sin(a);
    }
    for (int i = 0; i < n; i++) {
        int r = 0;
        for (int b = 0; b < lg; b++) if (i & (1 << b)) r |= 1 << (lg - 1 - b);
        f->rev[i] = r;
    }
    return 0;
}

void am_fft_free(am_fft *f) {
    free(f->cos_t); free(f->sin_t); free(f->rev);
    f->cos_t = f->sin_t = 0; f->rev = 0;
}

void am_fft_run(const am_fft *f, float *re, float *im, int inverse) {
    const int n = f->n;
    for (int i = 0; i < n; i++) {
        int j = f->rev[i];
        if (j > i) { float t = re[i]; re[i] = re[j]; re[j] = t; t = im[i]; im[i] = im[j]; im[j] = t; }
    }
    const float sgn = inverse ? -1.0f : 1.0f;
    for (int size = 2; size <= n; size <<= 1) {
        int half = size >> 1, step = n / size;
        for (int start = 0; start < n; start += size) {
            for (int k = 0; k < half; k++) {
                float wr = f->cos_t[k * step], wi = sgn * f->sin_t[k * step];
                int a = start + k, b = a + half;
                float xr = re[b] * wr - im[b] * wi;
                float xi = re[b] * wi + im[b] * wr;
                re[b] = re[a] - xr; im[b] = im[a] - xi;
                re[a] += xr;       im[a] += xi;
            }
        }
    }
}
