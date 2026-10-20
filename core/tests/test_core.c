/* Unit tests for the portable core (no audio hardware needed). Run: make test */
#include "audiomemo_core.h"
#include "../src/am_fft.h"
#include "../tools/wav.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int fails = 0;
#define CHECK(cond, ...) do { int ok_ = (cond); printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); printf("\n"); if (!ok_) fails++; } while (0)
static float db(double p) { return (float)(10 * log10(p + 1e-20)); }

static unsigned rs = 12345;
static float rnd(void) { rs = rs * 1103515245u + 12345u; return ((rs >> 9) & 0x3FFFFF) / (float)0x200000 - 1.f; }

/* speech-like signal: harmonic "voice" with gliding pitch + noise, gated by syllables */
static void speechlike(float *x, long n, int sr, float level, float f0, unsigned seed) {
    rs = seed; double ph = 0;
    for (long i = 0; i < n; i++) {
        double t = (double)i / sr;
        double syl = fmod(t, 0.32) < 0.22 ? 1.0 : 0.05;
        double pitch = f0 * (1 + 0.15 * sin(2 * M_PI * 0.7 * t));
        ph += 2 * M_PI * pitch / sr;
        double v = 0;
        for (int h = 1; h <= 20; h++) v += sin(h * ph) / h;
        v = 0.6 * v + 0.4 * rnd();
        x[i] = (float)(level * syl * v);
    }
}

static double energy(const float *x, long a, long b) { double e = 0; for (long i = a; i < b; i++) e += (double)x[i] * x[i]; return e / (b - a); }

static double band_energy(const float *x, long a, long b, int sr, double lo, double hi) {
    /* crude: average power of 1024-pt FFT frames in [lo,hi) */
    am_fft f; am_fft_init(&f, 1024);
    float re[1024], im[1024]; double tot = 0; int frames = 0;
    for (long s = a; s + 1024 <= b; s += 1024, frames++) {
        for (int i = 0; i < 1024; i++) { re[i] = x[s + i] * (float)(0.5 - 0.5 * cos(2 * M_PI * i / 1024)); im[i] = 0; }
        am_fft_run(&f, re, im, 0);
        for (int k = (int)(lo * 1024 / sr); k < (int)(hi * 1024 / sr); k++) tot += re[k] * re[k] + im[k] * im[k];
    }
    am_fft_free(&f);
    return tot / (frames ? frames : 1);
}

static void test_fft(void) {
    am_fft f; am_fft_init(&f, 1024);
    float re[1024], im[1024], o[1024];
    for (int i = 0; i < 1024; i++) { re[i] = o[i] = rnd(); im[i] = 0; }
    am_fft_run(&f, re, im, 0); am_fft_run(&f, re, im, 1);
    double err = 0; for (int i = 0; i < 1024; i++) err = fmax(err, fabs(re[i] / 1024 - o[i]));
    CHECK(err < 1e-4, "FFT round trip max error %.2e", err);
    am_fft_free(&f);
}

static void test_leveler(void) {
    am_leveler lv; am_leveler_init(&lv, 0.141f, 0.0032f, 0.5f, 16, 4);
    float g0, g1, blk = 512.f / 48000;
    for (int i = 0; i < (int)(6 / blk); i++) am_leveler_update(&lv, 0.0126f, blk, &g0, &g1);   /* -38 dBFS voice */
    float outdb = 20 * log10f(0.0126f * g1);
    CHECK(fabsf(outdb + 17) < 2, "leveler: quiet voice brought to %.1f dBFS (target -17 ± 2)", outdb);
    for (int i = 0; i < (int)(20 / blk); i++) am_leveler_update(&lv, 0.0008f, blk, &g0, &g1);  /* only noise */
    CHECK(g1 <= 4.04f, "leveler: noise only for 20 s -> gain %.3f (<= rest 4, noise not amplified)", g1);
    am_leveler lv2; am_leveler_init(&lv2, 0.141f, 0.0032f, 0.5f, 16, 4);
    for (int i = 0; i < (int)(0.5 / blk); i++) am_leveler_update(&lv2, 0.0126f, blk, &g0, &g1);
    CHECK(g1 < 8, "leveler: slow attack, gain %.2f after 0.5 s (< 8)", g1);
}

static void test_limiter(void) {
    am_limiter lim; am_limiter_init(&lim, 0.708f, 0.08f, 48000);
    float peak = 0;
    for (int i = 0; i < 48000; i++) { float l = 3 * sinf(i * 0.05f), r = l; am_limiter_process(&lim, &l, &r); if (fabsf(l) > peak) peak = fabsf(l); }
    CHECK(20 * log10f(peak) <= -1.0f, "limiter: +9.5 dBFS sine -> peak %.2f dBFS (<= -1)", 20 * log10f(peak));
}

static void test_aec(void) {
    const int sr = 48000; const long n = 24L * sr;
    float *far = calloc(n, 4), *near = calloc(n, 4), *noise = calloc(n, 4), *echo = calloc(n, 4), *mic = calloc(n, 4), *out = calloc(n + 2048, 4);
    /* far end talks 0–10 s and 15–21 s; near end talks 10–14 s and 16–20 s (double talk 16–20 s) */
    speechlike(far, n, sr, 0.25f, 180, 7);
    for (long i = 0; i < n; i++) { double t = (double)i / sr; if (!((t < 10) || (t >= 15 && t < 21))) far[i] = 0; }
    speechlike(near, n, sr, 0.05f, 120, 99);
    for (long i = 0; i < n; i++) { double t = (double)i / sr; if (!((t >= 10 && t < 14) || (t >= 16 && t < 20))) near[i] = 0; }
    /* background noise ~ -60 dBFS, gently low-passed */
    rs = 4242; float lp = 0; for (long i = 0; i < n; i++) { lp = 0.7f * lp + 0.3f * rnd(); noise[i] = 0.0025f * lp; }
    /* echo path: 38 ms delay, 60 ms exponential tail, gain ~ -6 dB */
    int D = (int)(0.038 * sr), L = (int)(0.06 * sr);
    float *h = malloc(sizeof(float) * L); rs = 77;
    for (int k = 0; k < L; k++) h[k] = (k == 0 ? 0.5f : 0.15f * rnd() * expf(-k / (0.012f * sr)));
    for (long i = 0; i < n; i++) {
        double acc = 0;
        for (int k = 0; k < L; k += 1) { long j = i - D - k; if (j >= 0) acc += h[k] * far[j]; }
        echo[i] = (float)acc;
        mic[i] = echo[i] + near[i] + noise[i];
    }
    am_aec *a = am_aec_create(sr);
    if (getenv("AEC_LINEAR")) am_aec_set_postfilter(a, 0);
    if (getenv("AEC_NOCN")) am_aec_set_comfort_noise(a, 0);
    int lat = am_aec_latency(a);
    for (long i = 0; i < n; i += 480) {
        int k = (int)(n - i < 480 ? n - i : 480); am_aec_process(a, mic + i, far + i, out + i, k);
        if (getenv("AEC_TRACE") && (i / 480) % 50 == 0) { am_aec_stats st; am_aec_get_stats(a, &st);
            printf("     trace t=%.2f erle=%.1f pf=%.1f dt=%d\n", (double)i / sr, st.erle_db, st.postfilter_db, st.double_talk); }
    }
    float *o = out + lat;                          /* aligned with input */
    long s = sr;
    if (getenv("AEC_DUMP")) {   /* write mic/out/near for listening and analysis */
        float *st = malloc(sizeof(float) * n * 3);
        for (long i = 0; i < n; i++) { st[i * 3] = mic[i]; st[i * 3 + 1] = o[i]; st[i * 3 + 2] = near[i] + noise[i]; }
        wav_write(getenv("AEC_DUMP"), st, n, 3, sr); free(st);
    }
    /* far end alone, converged: 6–10 s */
    double e_in = energy(echo, 6 * s, 10 * s), e_res = energy(o, 6 * s, 10 * s) - energy(noise, 6 * s, 10 * s);
    double nf_noise = energy(noise, 6 * s, 10 * s), nf_out = energy(o, 6 * s, 10 * s);
    CHECK(db(e_in) - db(e_res > 1e-20 ? e_res : 1e-20) >= 20, "AEC: echo reduced by %.1f dB (>= 20)", db(e_in) - db(e_res > 1e-20 ? e_res : 1e-20));
    CHECK(fabsf(db(nf_out) - db(nf_noise)) <= 3, "AEC: output floor during far-end-only %.1f dB vs room noise %.1f dB (within 3 dB)", db(nf_out), db(nf_noise));
    /* near end alone 10.5–14 s: untouched */
    double n_in = energy(mic, 10.5 * s, 14 * s), n_out = energy(o, 10.5 * s, 14 * s);
    CHECK(fabsf(db(n_out) - db(n_in)) <= 1, "AEC: near-end only, level change %.2f dB (|x| <= 1)", db(n_out) - db(n_in));
    /* double talk 16.5–20 s: near-end kept */
    double dn = energy(near, 16.5 * s, 20 * s) + energy(noise, 16.5 * s, 20 * s), dout = energy(o, 16.5 * s, 20 * s);
    CHECK(db(dout) - db(dn) >= -3, "AEC: double talk, near-end level %.1f dB vs clean near-end (>= -3)", db(dout) - db(dn));
    /* high frequencies of near-end (single talk) */
    double hf_in = band_energy(mic, 10.5 * s, 14 * s, sr, 4000, 8000), hf_out = band_energy(o, 10.5 * s, 14 * s, sr, 4000, 8000);
    CHECK(db(hf_out) - db(hf_in) >= -3, "AEC: near-end 4-8 kHz change %.1f dB (>= -3)", db(hf_out) - db(hf_in));
    int bad = 0; for (long i = 0; i < n; i++) if (!isfinite(out[i])) bad++;
    CHECK(bad == 0, "AEC: no NaN/Inf (%d)", bad);
    for (int t = 0; t < 24; t++) printf("     t=%2d s  in %6.1f  out %6.1f  near %6.1f dB\n", t, db(energy(mic, t * s, (t + 1) * s)), db(energy(o, t * s, (t + 1) * s)), db(energy(near, t * s, (t + 1) * s)));
    am_aec_stats st; am_aec_get_stats(a, &st);
    printf("     (stats: erle %.1f dB, est delay %.1f ms, bulk %.1f ms)\n", st.erle_db, st.est_delay_ms, st.delay_ms);
    am_aec_destroy(a);
    free(far); free(near); free(noise); free(echo); free(mic); free(out); free(h);
}

int main(void) {
    test_fft(); test_leveler(); test_limiter(); test_aec();
    printf(fails ? "\n%d FAILED\n" : "\nall passed\n", fails);
    return fails ? 1 : 0;
}
