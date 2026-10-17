// Rolling frame rate from actual drawable presentation times (seconds on the
// CACurrentMediaTime clock). Refresh ticks and discarded frames are not samples.
#pragma once
#include <math.h>
#include <stdlib.h>
#include <string.h>

#define NVN_FPS_SAMPLES 256
typedef struct {
    double times[NVN_FPS_SAMPLES], first;
    unsigned count, next;
} nvn_fps;

static inline void nvn_fps_push(nvn_fps *s, double time) {
    if (!isfinite(time) || time <= 0) return;
    if (!s->count || time < s->first) s->first = time;
    s->times[s->next++ % NVN_FPS_SAMPLES] = time;
    if (s->count < NVN_FPS_SAMPLES) s->count++;
}
static inline int nvn_fps_compare(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}
// Include the time since the most recent frame, so a stalled game decays to
// zero instead of leaving its last FPS on screen. During startup use the elapsed
// time since the first frame; at very high rates use the retained part of the ring.
static inline int nvn_fps_read(const nvn_fps *s, double now, double *fps, double *ms) {
    *fps = *ms = 0;
    if (!s->count || !isfinite(now)) return 0;
    double times[NVN_FPS_SAMPLES];
    memcpy(times, s->times, s->count * sizeof *times);
    qsort(times, s->count, sizeof *times, nvn_fps_compare);
    double begin = fmax(s->first, now - 1.0);
    if (s->count == NVN_FPS_SAMPLES) begin = fmax(begin, times[0]);
    double span = now - begin;
    if (span < 0.05) return 0;
    unsigned frames = 0;
    for (unsigned i = 0; i < s->count; i++) {
        // Callbacks can arrive out of order. Count a presentation timestamp only
        // once, even if two drawables report the same display refresh.
        if (times[i] > begin + 1e-9 && times[i] <= now && (!i || times[i] != times[i - 1])) frames++;
    }
    *fps = frames / span;
    *ms = frames ? 1000.0 / *fps : 0;
    return 1;
}
