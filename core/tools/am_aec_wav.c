/*
 * Offline AEC tool: reads a 2-channel WAV (left = microphone, right = loudspeaker reference),
 * writes the echo-cancelled microphone (latency removed, aligned with the input).
 *
 *   am_aec_wav in.wav out.wav [--linear-only] [--no-comfort-noise] [--stats]
 */
#include "audiomemo_core.h"
#include "wav.h"
#include <time.h>

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: %s in.wav out.wav [--linear-only] [--no-comfort-noise] [--stats]\n", argv[0]); return 2; }
    int linear = 0, cn = 1, stats = 0;
    for (int i = 3; i < argc; i++) {
        if (!strcmp(argv[i], "--linear-only")) linear = 1;
        else if (!strcmp(argv[i], "--no-comfort-noise")) cn = 0;
        else if (!strcmp(argv[i], "--stats")) stats = 1;
        else if (!strncmp(argv[i], "--set=", 6)) { /* --set=name:value, applied after create */ }
    }
    wav_t w;
    if (wav_read(argv[1], &w) || w.channels < 2) { fprintf(stderr, "need a 2-channel wav\n"); return 1; }
    am_aec *a = am_aec_create(w.rate);
    am_aec_set_postfilter(a, !linear);
    am_aec_set_comfort_noise(a, cn);
    for (int i = 3; i < argc; i++) if (!strncmp(argv[i], "--set=", 6)) {
        char nm[32]; float v; if (sscanf(argv[i] + 6, "%31[^:]:%f", nm, &v) == 2) am_aec_set_param(a, nm, v);
    }
    int lat = am_aec_latency(a);
    long n = w.frames;
    float *mic = malloc(sizeof(float) * (n + lat)), *ref = malloc(sizeof(float) * (n + lat)), *out = malloc(sizeof(float) * (n + lat));
    for (long i = 0; i < n + lat; i++) {
        mic[i] = i < n ? w.data[i * w.channels] : 0;
        ref[i] = i < n ? w.data[i * w.channels + 1] : 0;
    }
    clock_t t0 = clock();
    for (long i = 0; i < n + lat; i += 512) {
        int k = (int)((n + lat - i) < 512 ? (n + lat - i) : 512);
        am_aec_process(a, mic + i, ref + i, out + i, k);
        if (stats && (i / 512) % 94 == 0) {
            am_aec_stats s; am_aec_get_stats(a, &s);
            fprintf(stderr, "t=%5.1fs erle=%5.1f dB pf=%5.1f dB dt=%d bulk=%.1f ms est=%.1f ms\n",
                    (double)i / w.rate, s.erle_db, s.postfilter_db, s.double_talk, s.delay_ms, s.est_delay_ms);
        }
    }
    double cpu = (double)(clock() - t0) / CLOCKS_PER_SEC;
    fprintf(stderr, "processed %.1f s of audio in %.3f s CPU (%.2f%% of one core in real time)\n",
            (double)n / w.rate, cpu, 100.0 * cpu / ((double)n / w.rate));
    wav_write(argv[2], out + lat, n, 1, w.rate);
    am_aec_destroy(a);
    return 0;
}
