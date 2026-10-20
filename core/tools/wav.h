/* Tiny WAV reader/writer for the offline tools (16-bit PCM or 32-bit float; any channel count). */
#ifndef AM_WAV_H
#define AM_WAV_H
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

typedef struct { int rate, channels; long frames; float *data; } wav_t;   /* interleaved */

static int wav_read(const char *path, wav_t *w) {
    FILE *f = fopen(path, "rb"); if (!f) return -1;
    char id[4]; uint32_t sz; uint16_t fmt = 0, ch = 0, bits = 0; uint32_t rate = 0;
    if (fread(id, 1, 4, f) != 4 || memcmp(id, "RIFF", 4)) { fclose(f); return -1; }
    fread(&sz, 4, 1, f); fread(id, 1, 4, f);
    w->data = NULL;
    while (fread(id, 1, 4, f) == 4 && fread(&sz, 4, 1, f) == 1) {
        if (!memcmp(id, "fmt ", 4)) {
            fread(&fmt, 2, 1, f); fread(&ch, 2, 1, f); fread(&rate, 4, 1, f);
            fseek(f, 6, SEEK_CUR); fread(&bits, 2, 1, f); fseek(f, sz - 16, SEEK_CUR);
            if (fmt == 0xFFFE) fmt = bits == 32 ? 3 : 1;
        } else if (!memcmp(id, "data", 4)) {
            int bps = bits / 8; long n = sz / (bps * ch);
            w->data = (float *)malloc(sizeof(float) * n * ch);
            for (long i = 0; i < n * ch; i++) {
                if (fmt == 3 && bits == 32) { float v; fread(&v, 4, 1, f); w->data[i] = v; }
                else { int16_t v; fread(&v, 2, 1, f); w->data[i] = v / 32768.f; }
            }
            w->rate = rate; w->channels = ch; w->frames = n;
            break;
        } else fseek(f, sz, SEEK_CUR);
    }
    fclose(f);
    return w->data ? 0 : -1;
}

static int wav_write(const char *path, const float *data, long frames, int channels, int rate) {
    FILE *f = fopen(path, "wb"); if (!f) return -1;
    uint32_t dsz = (uint32_t)(frames * channels * 4), rsz = 36 + dsz, rate32 = rate, br = rate * channels * 4;
    uint16_t fmt = 3, ch = channels, ba = channels * 4, bits = 32; uint32_t sixteen = 16;
    fwrite("RIFF", 1, 4, f); fwrite(&rsz, 4, 1, f); fwrite("WAVEfmt ", 1, 8, f); fwrite(&sixteen, 4, 1, f);
    fwrite(&fmt, 2, 1, f); fwrite(&ch, 2, 1, f); fwrite(&rate32, 4, 1, f); fwrite(&br, 4, 1, f);
    fwrite(&ba, 2, 1, f); fwrite(&bits, 2, 1, f); fwrite("data", 1, 4, f); fwrite(&dsz, 4, 1, f);
    fwrite(data, 4, (size_t)(frames * channels), f);
    fclose(f); return 0;
}
#endif
