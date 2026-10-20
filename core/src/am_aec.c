/*
 * Loudspeaker echo canceller.
 *
 * Linear part: partitioned-block frequency-domain adaptive filter (overlap-save),
 *   block N = 512 (at 48 kHz ~10.7 ms), FFT M = 2N, P partitions covering ~128 ms after a
 *   bulk delay. Gradient-constrained, step normalised per frequency bin by the smoothed
 *   reference power (NLMS).
 * Delay: the filter itself spans 0…128 ms. In addition, every 2 s the acoustic delay is
 *   estimated with GCC-PHAT on an 8 kHz decimated copy (cheap enough for the audio thread);
 *   when the echo falls outside the filter span (e.g. Bluetooth / HDMI speakers) the reference
 *   is delayed ("bulk delay") and the filter re-converges.
 * Double talk: once converged, if the error power is far above the expected residual echo,
 *   adaptation slows to 5 % so near-end speech is not learned as echo.
 * Post-filter (light): STFT (sqrt-Hann, 50 % overlap). Per bin, residual echo is estimated
 *   as lambda_k * |Y_k|^2, where lambda_k is learned only while the far end talks alone.
 *   Gain floor -10 dB, smoothed in time and frequency (no "musical noise"). Whatever is
 *   suppressed is replaced by comfort noise at the tracked background-noise level, so the
 *   background stays one steady, natural floor. Not a noise reducer: with no reference
 *   signal the gain is exactly 1 and no noise is added.
 * Latency: 2N samples.
 */
#include "audiomemo_core.h"
#include "am_fft.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

#define AEC_N 512
#define AEC_M 1024
#define AEC_P 12
#define EST_RATE 8000
#define EST_LEN 8000          /* 1 s of decimated history          */
#define EST_FFT 16384
#define EST_MAXLAG 4000       /* 0.5 s                              */

struct am_aec {
    int sr, decim;
    am_fft fft;
    /* filter + reference spectra history */
    float *Wr[AEC_P], *Wi[AEC_P], *Xr[AEC_P], *Xi[AEC_P];
    int xhead;
    float Sxx[AEC_M];
    /* block FIFO */
    float refhist[AEC_M], micin[AEC_N], refin[AEC_N];
    int incount;
    float outfifo[4 * AEC_M];
    int out_r, out_w, out_n;
    /* bulk delay */
    float *dline; int dlen, dw, bulk, pending_bulk;
    /* stats */
    float pyy_s, pee_s, pxx_s, prr_s, leak, erle;
    int double_talk;
    float gmean, est_ms;
    /* post-filter */
    int pf_on, cn_on;
    float p_mu, p_cohk, p_over;   /* tunables (am_aec_set_param) */
    float win[AEC_M], ebuf[AEC_M], ybuf[AEC_M], ola[AEC_N];
    float See[AEC_M / 2 + 1], Slong[AEC_M / 2 + 1], Syy[AEC_M / 2 + 1], noise[AEC_M / 2 + 1], lambda[AEC_M / 2 + 1], gain[AEC_M / 2 + 1];
    unsigned int rng;
    /* scratch */
    float tr[AEC_M], ti[AEC_M], yr[AEC_M], yi[AEC_M], er[AEC_M], ei[AEC_M], gr[AEC_M], gi[AEC_M];
    float step[AEC_M], ebl[AEC_N];
    /* per-bin coherence between the error and the delay-aligned reference partition:
       ~ fraction of the error that is still echo → per-bin step size (optimal-step proxy) */
    float Sex_r[AEC_M], Sex_i[AEC_M], See2[AEC_M], Sxx2[AEC_M];
    /* delay estimation (decimated) */
    am_fft efft;
    float *est_mic, *est_ref, *est_a_r, *est_a_i, *est_b_r, *est_b_i;
    int est_w; float dec_m, dec_r; int dec_k; long since_est;
};

static void clear_filter(am_aec *a) {
    for (int p = 0; p < AEC_P; p++) {
        memset(a->Wr[p], 0, sizeof(float) * AEC_M); memset(a->Wi[p], 0, sizeof(float) * AEC_M);
        memset(a->Xr[p], 0, sizeof(float) * AEC_M); memset(a->Xi[p], 0, sizeof(float) * AEC_M);
    }
    a->erle = 1.f;
}

am_aec *am_aec_create(int sample_rate) {
    if (sample_rate < 8000 || sample_rate > 192000) return NULL;
    am_aec *a = (am_aec *)calloc(1, sizeof(am_aec));
    if (!a) return NULL;
    a->sr = sample_rate;
    a->decim = sample_rate / EST_RATE; if (a->decim < 1) a->decim = 1;
    int ok = am_fft_init(&a->fft, AEC_M) == 0 && am_fft_init(&a->efft, EST_FFT) == 0;
    for (int p = 0; p < AEC_P && ok; p++) {
        a->Wr[p] = (float *)calloc(AEC_M, sizeof(float)); a->Wi[p] = (float *)calloc(AEC_M, sizeof(float));
        a->Xr[p] = (float *)calloc(AEC_M, sizeof(float)); a->Xi[p] = (float *)calloc(AEC_M, sizeof(float));
        ok = a->Wr[p] && a->Wi[p] && a->Xr[p] && a->Xi[p];
    }
    a->dlen = (int)(sample_rate * 0.6) + 1;
    a->dline = (float *)calloc((size_t)a->dlen, sizeof(float));
    a->est_mic = (float *)calloc(EST_LEN, sizeof(float)); a->est_ref = (float *)calloc(EST_LEN, sizeof(float));
    a->est_a_r = (float *)calloc(EST_FFT, sizeof(float)); a->est_a_i = (float *)calloc(EST_FFT, sizeof(float));
    a->est_b_r = (float *)calloc(EST_FFT, sizeof(float)); a->est_b_i = (float *)calloc(EST_FFT, sizeof(float));
    if (!ok || !a->dline || !a->est_mic || !a->est_ref || !a->est_a_r || !a->est_a_i || !a->est_b_r || !a->est_b_i) {
        am_aec_destroy(a); return NULL;
    }
    for (int i = 0; i < AEC_M; i++) a->win[i] = (float)sin(M_PI * i / AEC_M);
    a->pf_on = 1; a->cn_on = 1; a->rng = 0x1234567u;
    a->p_mu = 1.3f; a->p_cohk = 16.f; a->p_over = 1.5f;
    am_aec_reset(a);
    return a;
}

void am_aec_destroy(am_aec *a) {
    if (!a) return;
    for (int p = 0; p < AEC_P; p++) { free(a->Wr[p]); free(a->Wi[p]); free(a->Xr[p]); free(a->Xi[p]); }
    free(a->dline); free(a->est_mic); free(a->est_ref);
    free(a->est_a_r); free(a->est_a_i); free(a->est_b_r); free(a->est_b_i);
    am_fft_free(&a->fft); am_fft_free(&a->efft);
    free(a);
}

void am_aec_reset(am_aec *a) {
    clear_filter(a);
    for (int k = 0; k < AEC_M; k++) a->Sxx[k] = 1e-6f;
    memset(a->refhist, 0, sizeof a->refhist);
    a->incount = 0;
    memset(a->outfifo, 0, sizeof a->outfifo);
    a->out_r = 0; a->out_w = AEC_N; a->out_n = AEC_N;     /* one block of zeros: latency N (+N from OLA) */
    memset(a->dline, 0, sizeof(float) * (size_t)a->dlen);
    a->dw = 0; a->bulk = 0; a->pending_bulk = -1;
    a->pyy_s = a->pee_s = a->pxx_s = a->prr_s = 0; a->leak = 0.3f; a->double_talk = 0; a->gmean = 1; a->est_ms = -1;
    memset(a->ebuf, 0, sizeof a->ebuf); memset(a->ybuf, 0, sizeof a->ybuf); memset(a->ola, 0, sizeof a->ola);
    for (int k = 0; k <= AEC_M / 2; k++) { a->See[k] = a->Syy[k] = a->Slong[k] = 0; a->noise[k] = 1e6f; a->lambda[k] = 0.1f;   /* noise starts high: the minimum tracker pulls it down fast */ a->gain[k] = 1; }
    memset(a->Sex_r, 0, sizeof a->Sex_r); memset(a->Sex_i, 0, sizeof a->Sex_i);
    memset(a->See2, 0, sizeof a->See2); memset(a->Sxx2, 0, sizeof a->Sxx2);
    memset(a->est_mic, 0, sizeof(float) * EST_LEN); memset(a->est_ref, 0, sizeof(float) * EST_LEN);
    a->est_w = 0; a->dec_m = a->dec_r = 0; a->dec_k = 0; a->since_est = 0;
}

int  am_aec_latency(const am_aec *a) { (void)a; return 2 * AEC_N; }
void am_aec_set_postfilter(am_aec *a, int on) { a->pf_on = on; }
void am_aec_set_comfort_noise(am_aec *a, int on) { a->cn_on = on; }

void am_aec_get_stats(const am_aec *a, am_aec_stats *o) {
    o->erle_db = 10.f * log10f(a->erle > 1 ? a->erle : 1);
    o->postfilter_db = 20.f * log10f(a->gmean > 1e-3f ? a->gmean : 1e-3f);
    o->double_talk = a->double_talk;
    o->delay_ms = (float)a->bulk * 1000.f / (float)a->sr;
    o->est_delay_ms = a->est_ms;
}

static inline float frand(am_aec *a) {
    a->rng = a->rng * 1664525u + 1013904223u;
    return (float)(a->rng >> 8) / 16777216.0f;
}

static void push_out(am_aec *a, float v) {
    a->outfifo[a->out_w] = v; a->out_w = (a->out_w + 1) % (4 * AEC_M); a->out_n++;
}

/* GCC-PHAT on the decimated history; runs on the audio thread every 2 s (~16k-point FFTs). */
static void estimate_delay(am_aec *a) {
    float e = 0;
    for (int i = 0; i < EST_LEN; i++) e += a->est_ref[i] * a->est_ref[i];
    if (e / EST_LEN < 1e-5f) return;                      /* reference too quiet (< -50 dBFS) */
    memset(a->est_a_r, 0, sizeof(float) * EST_FFT); memset(a->est_a_i, 0, sizeof(float) * EST_FFT);
    memset(a->est_b_r, 0, sizeof(float) * EST_FFT); memset(a->est_b_i, 0, sizeof(float) * EST_FFT);
    for (int i = 0; i < EST_LEN; i++) {
        int k = (a->est_w + i) % EST_LEN;
        a->est_a_r[i] = a->est_mic[k]; a->est_b_r[i] = a->est_ref[k];
    }
    am_fft_run(&a->efft, a->est_a_r, a->est_a_i, 0);
    am_fft_run(&a->efft, a->est_b_r, a->est_b_i, 0);
    for (int k = 0; k < EST_FFT; k++) {
        float re = a->est_a_r[k] * a->est_b_r[k] + a->est_a_i[k] * a->est_b_i[k];
        float im = a->est_a_i[k] * a->est_b_r[k] - a->est_a_r[k] * a->est_b_i[k];
        float mag = sqrtf(re * re + im * im); if (mag < 1e-12f) mag = 1e-12f;
        a->est_a_r[k] = re / mag; a->est_a_i[k] = im / mag;
    }
    am_fft_run(&a->efft, a->est_a_r, a->est_a_i, 1);
    int best = 0; float bv = 0, sum = 0;
    for (int k = 0; k < EST_MAXLAG; k++) { float v = fabsf(a->est_a_r[k]); sum += v; if (v > bv) { bv = v; best = k; } }
    if (bv < 8.f * sum / EST_MAXLAG) return;              /* no clear peak (no echo, or double talk) */
    a->est_ms = best * 1000.f / EST_RATE;
    int d = (int)((double)best * a->sr / EST_RATE);
    int cover = AEC_P * AEC_N;
    if (d < a->bulk + a->sr / 200 || d > a->bulk + cover - (int)(0.03 * a->sr)) {
        int nb = d - (int)(0.02 * a->sr); if (nb < 0) nb = 0;
        if (nb > a->dlen - 1) nb = a->dlen - 1;
        if (abs(nb - a->bulk) > (int)(0.008 * a->sr)) a->pending_bulk = nb;
    }
}

static void process_block(am_aec *a) {
    const int N = AEC_N, M = AEC_M, H = AEC_M / 2;
    const float sc = 1.0f / M;
    /* reference spectrum (overlap-save: [previous block, this block]) */
    for (int i = 0; i < N; i++) { a->refhist[i] = a->refhist[i + N]; a->refhist[i + N] = a->refin[i]; }
    a->xhead = (a->xhead + AEC_P - 1) % AEC_P;
    float *xr = a->Xr[a->xhead], *xi = a->Xi[a->xhead];
    memcpy(xr, a->refhist, sizeof(float) * M); memset(xi, 0, sizeof(float) * M);
    am_fft_run(&a->fft, xr, xi, 0);

    float prr = 0;
    for (int i = 0; i < N; i++) prr += a->refin[i] * a->refin[i];
    prr /= N;
    for (int k = 0; k < M; k++) a->Sxx[k] = 0.9f * a->Sxx[k] + 0.1f * (xr[k] * xr[k] + xi[k] * xi[k]);

    /* echo estimate */
    memset(a->yr, 0, sizeof a->yr); memset(a->yi, 0, sizeof a->yi);
    for (int p = 0; p < AEC_P; p++) {
        const float *Xr = a->Xr[(a->xhead + p) % AEC_P], *Xi = a->Xi[(a->xhead + p) % AEC_P];
        const float *Wr = a->Wr[p], *Wi = a->Wi[p];
        for (int k = 0; k < M; k++) {
            a->yr[k] += Wr[k] * Xr[k] - Wi[k] * Xi[k];
            a->yi[k] += Wr[k] * Xi[k] + Wi[k] * Xr[k];
        }
    }
    am_fft_run(&a->fft, a->yr, a->yi, 1);
    float pyy = 0, pee = 0, pxx = 0;
    for (int i = 0; i < N; i++) {
        float y = a->yr[N + i] * sc, x = a->micin[i], e = x - y;
        a->ebl[i] = e; pyy += y * y; pee += e * e; pxx += x * x;
    }
    pyy /= N; pee /= N; pxx /= N;

    const int ref_active = prr > 1e-7f;
    const float s = 0.85f;
    a->pyy_s = s * a->pyy_s + (1 - s) * pyy;
    a->pee_s = s * a->pee_s + (1 - s) * pee;
    a->pxx_s = s * a->pxx_s + (1 - s) * pxx;
    a->prr_s = s * a->prr_s + (1 - s) * prr;
    if (ref_active && a->pxx_s > 1e-9f) {
        float r = a->pxx_s / (a->pee_s > 1e-12f ? a->pee_s : 1e-12f); if (r > 1000) r = 1000;
        a->erle = 0.98f * a->erle + 0.02f * r;
    }
    /* divergence guard: the output must never be much louder than the microphone */
    if (ref_active && a->pxx_s > 1e-10f && a->pee_s > 4.f * a->pxx_s) { clear_filter(a); a->pee_s = a->pxx_s; }
    const int converged = a->erle > 4.f;
    const float residual = a->leak * a->pyy_s;
    /* double talk = near-end at least comparable to the (estimated) echo */
    a->double_talk = converged && a->pyy_s > 0 && a->pee_s > 2.f * a->pyy_s;
    /* step: full while the error is mostly echo; scaled down by echo/error when someone talks
       (never fully frozen, so a constantly noisy room cannot lock the filter out) */
    float mu = 0.f;
    if (ref_active) {
        mu = a->p_mu;   /* scaled per bin below by how much of the error is still echo */
    }
    if (ref_active && converged && !a->double_talk && a->pyy_s > 1e-9f) {
        float l = a->pee_s / a->pyy_s; if (l < 0.0003f) l = 0.0003f; if (l > 1) l = 1;
        /* falls fast, rises slowly: undetected near-end speech can't inflate it much */
        a->leak += (l - a->leak) * (l < a->leak ? 0.05f : 0.005f);
    }

    if (mu > 0) {
        memset(a->er, 0, sizeof(float) * N); memcpy(a->er + N, a->ebl, sizeof(float) * N);
        memset(a->ei, 0, sizeof a->ei);
        am_fft_run(&a->fft, a->er, a->ei, 0);
        /* regularisation relative to the average reference power: quiet bins don't get huge steps */
        float mean_sxx = 0; for (int k = 0; k < M; k++) mean_sxx += a->Sxx[k]; mean_sxx /= M;
        float delta = 0.005f * mean_sxx + 1e-6f;
        /* partition holding the direct echo path: the one with the most filter energy
           (falls back to the GCC-PHAT estimate, or "no info yet" → full step everywhere) */
        int pd = -1; float best = 0;
        for (int p = 0; p < AEC_P; p++) {
            float e = 0; const float *wr = a->Wr[p], *wi = a->Wi[p];
            for (int k = 0; k < M; k += 8) e += wr[k] * wr[k] + wi[k] * wi[k];
            if (e > best) { best = e; pd = p; }
        }
        if (best < 1e-12f) pd = -1;
        if (pd < 0 && a->est_ms >= 0) {
            pd = (int)(((double)a->est_ms * a->sr / 1000.0 - a->bulk) / N + 0.5);
            if (pd < 0) pd = 0; if (pd > AEC_P - 1) pd = AEC_P - 1;
        }
        const int no_info = pd < 0;
        if (pd < 0) pd = 0;
        const float *Xd_r = a->Xr[(a->xhead + pd) % AEC_P], *Xd_i = a->Xi[(a->xhead + pd) % AEC_P];
        for (int k = 0; k < M; k++) {
            float cr = a->er[k] * Xd_r[k] + a->ei[k] * Xd_i[k];      /* E · conj(Xd) */
            float ci = a->ei[k] * Xd_r[k] - a->er[k] * Xd_i[k];
            a->Sex_r[k] = 0.9f * a->Sex_r[k] + 0.1f * cr;
            a->Sex_i[k] = 0.9f * a->Sex_i[k] + 0.1f * ci;
            a->See2[k] = 0.9f * a->See2[k] + 0.1f * (a->er[k] * a->er[k] + a->ei[k] * a->ei[k]);
            a->Sxx2[k] = 0.9f * a->Sxx2[k] + 0.1f * (Xd_r[k] * Xd_r[k] + Xd_i[k] * Xd_i[k]);
            float coh = (a->Sex_r[k] * a->Sex_r[k] + a->Sex_i[k] * a->Sex_i[k]) / (a->See2[k] * a->Sxx2[k] + 1e-20f);
            float w = no_info ? 1.f : a->p_cohk * coh; if (w < 0.02f) w = 0.02f; if (w > 1) w = 1;
            a->step[k] = mu * w / ((a->Sxx[k] + delta) * AEC_P);
        }
        for (int p = 0; p < AEC_P; p++) {
            const float *Xr = a->Xr[(a->xhead + p) % AEC_P], *Xi = a->Xi[(a->xhead + p) % AEC_P];
            for (int k = 0; k < M; k++) {
                a->gr[k] = (Xr[k] * a->er[k] + Xi[k] * a->ei[k]) * a->step[k];
                a->gi[k] = (Xr[k] * a->ei[k] - Xi[k] * a->er[k]) * a->step[k];
            }
            /* gradient constraint: keep only the first N taps */
            am_fft_run(&a->fft, a->gr, a->gi, 1);
            for (int i = 0; i < N; i++) { a->gr[i] *= sc; a->gi[i] *= sc; }
            for (int i = N; i < M; i++) { a->gr[i] = 0; a->gi[i] = 0; }
            am_fft_run(&a->fft, a->gr, a->gi, 0);
            float *Wr = a->Wr[p], *Wi = a->Wi[p];
            for (int k = 0; k < M; k++) { Wr[k] += a->gr[k]; Wi[k] += a->gi[k]; }
        }
    }

    /* post-filter: light residual suppression + comfort noise (WOLA) */
    for (int i = 0; i < N; i++) {
        a->ebuf[i] = a->ebuf[i + N]; a->ebuf[i + N] = a->ebl[i];
        a->ybuf[i] = a->ybuf[i + N]; a->ybuf[i + N] = a->micin[i] - a->ebl[i];
    }
    if (!a->pf_on) {
        for (int i = 0; i < N; i++) push_out(a, a->ebuf[i]);     /* keep the same 2N latency */
        a->gmean = 1;
        return;
    }
    for (int i = 0; i < M; i++) { a->tr[i] = a->ebuf[i] * a->win[i]; a->ti[i] = 0; a->yr[i] = a->ybuf[i] * a->win[i]; a->yi[i] = 0; }
    am_fft_run(&a->fft, a->tr, a->ti, 0);
    am_fft_run(&a->fft, a->yr, a->yi, 0);
    const int active = ref_active && converged;
    for (int k = 0; k <= H; k++) {
        float pe = a->tr[k] * a->tr[k] + a->ti[k] * a->ti[k];
        float py = a->yr[k] * a->yr[k] + a->yi[k] * a->yi[k];
        a->See[k] = 0.7f * a->See[k] + 0.3f * pe;
        a->Syy[k] = 0.7f * a->Syy[k] + 0.3f * py;
        /* background noise: minimum tracking (fast down, ~1 dB/s up) */
        /* background noise: minimum tracking on a longer-smoothed power (less variance → less low bias);
           while the speaker plays the error still holds residual echo → only let the estimate go down */
        a->Slong[k] = 0.92f * a->Slong[k] + 0.08f * pe;
        if (a->Slong[k] < a->noise[k]) a->noise[k] = 0.9f * a->noise[k] + 0.1f * a->Slong[k];
        else if (!ref_active) a->noise[k] *= 1.0025f;
        /* learn the residual-echo ratio only when this bin looks like "echo residue + noise",
           not when something new (near-end voice) appears in it */
        int bin_quiet = a->See[k] < 4.f * (a->lambda[k] * a->Syy[k] + a->noise[k] * 1.6f);
        if (active && !a->double_talk && bin_quiet && a->Syy[k] > 1e-12f) {
            float d = a->See[k] - a->noise[k]; if (d < 0) d = 0;
            float l = d / a->Syy[k]; if (l < 0.0003f) l = 0.0003f; if (l > 1) l = 1;
            a->lambda[k] += (l - a->lambda[k]) * (l < a->lambda[k] ? 0.05f : 0.03f);
        }
        float g = 1;
        if (active) {
            /* far end alone: residual echo can be pushed down to the noise floor (comfort noise fills in);
               double talk: at most -3 dB so the near-end voice is never eaten */
            float res = a->lambda[k] * a->Syy[k];
            /* near-end present in this bin (error well above the expected residual) → gentle */
            int near_bin = a->double_talk || a->See[k] > 3.f * res;
            float over = near_bin ? 1.0f : a->p_over;
            float floor_g = near_bin ? 0.708f : 0.056f;
            res *= over;
            g = 1 - res / (a->See[k] + 1e-12f);
            if (g < floor_g) g = floor_g;
        }
        a->gain[k] = g < a->gain[k] ? 0.5f * a->gain[k] + 0.5f * g : 0.6f * a->gain[k] + 0.4f * g;
    }
    /* 3-tap frequency smoothing that never raises a gain (smooths isolated dips' neighbours down
       instead of lifting the dip — strong echo harmonics stay suppressed, no isolated "tones") */
    { float prev = a->gain[0];
      for (int k = 1; k < H; k++) {
          float cur = a->gain[k], avg = (prev + cur + a->gain[k + 1]) / 3;
          a->step[k] = avg < cur ? avg : cur; prev = cur;
      }
      for (int k = 1; k < H; k++) a->gain[k] = a->step[k]; }
    float gsum = 0;
    for (int k = 0; k <= H; k++) {
        float g = a->gain[k];
        float o_r = a->tr[k] * g, o_i = a->ti[k] * g;
        gsum += g;
        if (a->cn_on && g < 0.999f && k > 0 && k < H) {
            float amp = sqrtf((1 - g * g) * a->noise[k] * 1.6f);   /* 1.6: minimum-statistics bias */
            float ph = frand(a) * 6.2831853f;
            o_r += amp * cosf(ph); o_i += amp * sinf(ph);
        }
        a->gr[k] = o_r; a->gi[k] = o_i;
        if (k > 0 && k < H) { a->gr[M - k] = o_r; a->gi[M - k] = -o_i; }
    }
    a->gmean = gsum / (H + 1);
    am_fft_run(&a->fft, a->gr, a->gi, 1);
    for (int i = 0; i < N; i++) push_out(a, a->ola[i] + a->gr[i] * sc * a->win[i]);
    for (int i = 0; i < N; i++) a->ola[i] = a->gr[N + i] * sc * a->win[N + i];
}

void am_aec_process(am_aec *a, const float *mic, const float *ref, float *out, int n) {
    for (int i = 0; i < n; i++) {
        /* decimated history for delay estimation */
        a->dec_m += mic[i]; a->dec_r += ref[i];
        if (++a->dec_k == a->decim) {
            a->est_mic[a->est_w] = a->dec_m / a->decim; a->est_ref[a->est_w] = a->dec_r / a->decim;
            a->est_w = (a->est_w + 1) % EST_LEN;
            a->dec_m = a->dec_r = 0; a->dec_k = 0;
        }
        if (++a->since_est >= 2L * a->sr) { a->since_est = 0; estimate_delay(a); }
        if (a->pending_bulk >= 0 && a->incount == 0) {
            a->bulk = a->pending_bulk; a->pending_bulk = -1; clear_filter(a);
        }
        /* reference through the bulk delay line */
        a->dline[a->dw] = ref[i];
        int rd = a->dw - a->bulk; if (rd < 0) rd += a->dlen;
        float r = a->dline[rd];
        a->dw = (a->dw + 1) % a->dlen;

        a->micin[a->incount] = mic[i]; a->refin[a->incount] = r;
        if (++a->incount == AEC_N) { process_block(a); a->incount = 0; }
    }
    for (int i = 0; i < n; i++) {
        if (a->out_n > 0) { out[i] = a->outfifo[a->out_r]; a->out_r = (a->out_r + 1) % (4 * AEC_M); a->out_n--; }
        else out[i] = 0;
    }
}

int am_aec_set_param(am_aec *a, const char *name, float v) {
    if (!strcmp(name, "mu")) a->p_mu = v;
    else if (!strcmp(name, "coh")) a->p_cohk = v;
    else if (!strcmp(name, "over")) a->p_over = v;
    else return -1;
    return 0;
}
