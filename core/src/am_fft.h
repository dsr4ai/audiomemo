/* Minimal radix-2 complex FFT (internal). Twiddles/bit-reversal precomputed at init. */
#ifndef AM_FFT_H
#define AM_FFT_H
typedef struct {
    int n, log2n;
    float *cos_t, *sin_t;   /* n/2 twiddles */
    int *rev;               /* bit-reversal permutation */
} am_fft;
int  am_fft_init(am_fft *f, int n);        /* n power of two; returns 0 on success */
void am_fft_free(am_fft *f);
/* In-place complex FFT. inverse=1 computes the unscaled inverse. */
void am_fft_run(const am_fft *f, float *re, float *im, int inverse);
#endif
