/* Automatic level balancing + stereo-linked peak limiter. */
#include "audiomemo_core.h"
#include <math.h>

static float coeff(float seconds, float block) { return 1.f - expf(-block / (seconds > 0.001f ? seconds : 0.001f)); }

void am_leveler_init(am_leveler *lv, float target, float gate, float min_gain, float max_gain, float rest_gain) {
    lv->target = target; lv->gate = gate;
    lv->min_gain = min_gain; lv->max_gain = max_gain; lv->rest_gain = rest_gain;
    lv->attack_s = 0.4f;       /* turning down             */
    lv->release_s = 2.5f;      /* turning up: slow, no pumping */
    lv->gate_release_s = 2.f;  /* back to rest gain when only noise is present */
    lv->env_s = 0.3f;
    lv->gain = rest_gain; lv->env = 0;
}

void am_leveler_update(am_leveler *lv, float rms, float block_s, float *g0, float *g1) {
    *g0 = lv->gain;
    lv->env += (rms - lv->env) * coeff(lv->env_s, block_s);
    if (lv->env > lv->gate) {
        float desired = lv->target / (lv->env > 1e-6f ? lv->env : 1e-6f);
        if (desired < lv->min_gain) desired = lv->min_gain;
        if (desired > lv->max_gain) desired = lv->max_gain;
        float tc = desired < lv->gain ? lv->attack_s : lv->release_s;
        lv->gain += (desired - lv->gain) * coeff(tc, block_s);
    } else {
        lv->gain += (lv->rest_gain - lv->gain) * coeff(lv->gate_release_s, block_s);
    }
    *g1 = lv->gain;
}

void am_limiter_init(am_limiter *lim, float ceiling, float release_seconds, double sample_rate) {
    lim->ceiling = ceiling;
    lim->release_coeff = 1.f - expf(-1.f / ((float)sample_rate * release_seconds));
    lim->g = 1;
}

void am_limiter_process(am_limiter *lim, float *l, float *r) {
    float peak = fabsf(*l) > fabsf(*r) ? fabsf(*l) : fabsf(*r);
    float needed = peak * lim->g > lim->ceiling ? lim->ceiling / peak : 1.f;
    if (needed < lim->g) lim->g = needed; else lim->g += (1 - lim->g) * lim->release_coeff;
    float c = lim->ceiling;
    *l *= lim->g; *r *= lim->g;
    if (*l > c) *l = c; if (*l < -c) *l = -c;
    if (*r > c) *r = c; if (*r < -c) *r = -c;
}
