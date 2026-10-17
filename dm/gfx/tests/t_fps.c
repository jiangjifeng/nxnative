// Presentation rate, including stalls, skipped refreshes and delayed callbacks.
#include "../nvn/nvn_fps.h"
#include <assert.h>
#include <stdio.h>

static void expect(const nvn_fps *s, double now, double rate) {
    double fps, ms;
    assert(nvn_fps_read(s, now, &fps, &ms));
    assert(fabs(fps - rate) < 1e-6);
    assert(fabs(ms - (rate ? 1000 / rate : 0)) < 1e-6);
}
int main(void) {
    nvn_fps s = {0}; double fps, ms;
    assert(!nvn_fps_read(&s, 10, &fps, &ms));
    nvn_fps_push(&s, 0); nvn_fps_push(&s, -1);
    nvn_fps_push(&s, NAN); nvn_fps_push(&s, INFINITY);
    assert(!s.count);   // No drawable timing / discarded frames do not count.

    for (int hz = 30; hz <= 120; hz *= 2) {
        s = (nvn_fps){0};
        for (int i = 0; i <= hz; i++) nvn_fps_push(&s, 10 + (double)i / hz);
        expect(&s, 11, hz);
    }
    s = (nvn_fps){0};
    for (int i = 0; i <= 60; i += 2) nvn_fps_push(&s, 10 + i / 60.0);
    expect(&s, 11, 30);   // A new game frame every other 60 Hz refresh is 30 FPS.

    s = (nvn_fps){0};
    for (int i = 0; i <= 60; i++) nvn_fps_push(&s, 10 + i / 60.0);
    expect(&s, 10.5, 60);  // Startup uses elapsed time, not a full second.
    expect(&s, 11.5, 30);  // Include an ongoing stall, before another callback.
    expect(&s, 12.1, 0);
    for (int i = 0; i <= 60; i++) nvn_fps_push(&s, 20 + i / 60.0);
    expect(&s, 21, 60);    // Old samples do not lower the rate after recovery.

    s = (nvn_fps){0};
    for (int i = 60; i >= 0; i--) {
        nvn_fps_push(&s, 10 + i / 60.0);
        nvn_fps_push(&s, 10 + i / 60.0);
    }
    expect(&s, 11, 60);    // Callback order and duplicate refresh timestamps.

    for (int hz = 120; hz <= 600; hz += 480) {
        s = (nvn_fps){0};
        for (int i = 0; i <= 10 * hz; i++) nvn_fps_push(&s, 10 + (double)i / hz);
        expect(&s, 20, hz);   // Ring wrap, including more than 256 frames/second.
    }
    puts("FPS presentation statistics PASS");
    return 0;
}
