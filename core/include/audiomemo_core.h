/*
 * AudioMemo core — portable audio processing (C11, no platform dependencies).
 *
 *   - am_aec:      loudspeaker echo canceller (partitioned-block frequency-domain NLMS
 *                  + light residual-echo post-filter + comfort noise)
 *   - am_leveler:  automatic level balancing (slow attack/release, noise gate)
 *   - am_limiter:  stereo-linked peak limiter
 *
 * Real-time rules: every buffer is allocated in *_create / *_init. The *_process
 * functions never allocate, lock or block, so they are safe on an audio thread.
 *
 * Copyright 2026 BookAI and AudioMemo contributors. Licensed under the Apache License 2.0.
 */
#ifndef AUDIOMEMO_CORE_H
#define AUDIOMEMO_CORE_H

#ifdef __cplusplus
extern "C" {
#endif

/* ---------------------------------------------------------------- AEC */

typedef struct am_aec am_aec;

typedef struct {
    float erle_db;          /* echo return loss enhancement of the linear filter (smoothed) */
    float postfilter_db;    /* average post-filter gain (0 = no suppression)               */
    int   double_talk;      /* 1 while near-end speech is detected during far-end speech     */
    float delay_ms;         /* bulk delay currently applied to the reference                 */
    float est_delay_ms;     /* last acoustic delay estimate (-1 = none yet)                   */
} am_aec_stats;

/* sample_rate: 16000…48000. Returns NULL on allocation failure. */
am_aec *am_aec_create(int sample_rate);
void    am_aec_destroy(am_aec *aec);

/* Process n samples (any n). mic = microphone, ref = what is being played on the
 * speakers (the system mix, captured digitally before the speaker). out = echo-cancelled
 * microphone, delayed by am_aec_latency() samples. mic/ref/out may not alias. */
void am_aec_process(am_aec *aec, const float *mic, const float *ref, float *out, int n);

int  am_aec_latency(const am_aec *aec);          /* samples of fixed output delay           */
void am_aec_set_postfilter(am_aec *aec, int on); /* residual suppression + comfort noise     */
void am_aec_set_comfort_noise(am_aec *aec, int on);
void am_aec_reset(am_aec *aec);
/* Tuning knobs (defaults are the shipped values): "mu" step (1.3), "coh" coherence weight (16), "over" residual over-estimate (1.5). */
int  am_aec_set_param(am_aec *aec, const char *name, float value);
void am_aec_get_stats(const am_aec *aec, am_aec_stats *out);

/* ------------------------------------------------------------ leveler */

typedef struct {
    float target;      /* target RMS (linear)                               */
    float gate;        /* below this RMS envelope the gain drifts to rest   */
    float min_gain, max_gain, rest_gain;
    float attack_s, release_s, gate_release_s, env_s;
    float gain, env;   /* state */
} am_leveler;

void am_leveler_init(am_leveler *lv, float target, float gate, float min_gain, float max_gain, float rest_gain);
/* Update once per block. Returns gain at block start (*g0) and end (*g1) for interpolation. */
void am_leveler_update(am_leveler *lv, float block_rms, float block_seconds, float *g0, float *g1);

/* ------------------------------------------------------------ limiter */

typedef struct {
    float ceiling;     /* linear, e.g. 0.708 = -3 dBFS */
    float release_coeff;
    float g;
} am_limiter;

void am_limiter_init(am_limiter *lim, float ceiling, float release_seconds, double sample_rate);
void am_limiter_process(am_limiter *lim, float *l, float *r);   /* one stereo frame in place */

#ifdef __cplusplus
}
#endif
#endif
